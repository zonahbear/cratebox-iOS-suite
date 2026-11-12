"""Beat This! small0 (CPJKU/beat_this, MIT) -> Core ML, for Cratebox's beat / bar-1 analysis.

Runs on Linux (coreml.yml) or a Mac: Windows' coremltools can't write an mlprogram. The network only: input
"spect" = log-mel spectrogram [1, 1500, 128] (30 s at 50 fps, beat_this.preprocessing.LogMelSpect), outputs
"beat" and "downbeat" logits [1, 1500]. The mel front end and the peak picking stay in Swift.

Two changes before tracing, both checked against the untouched model below:
- rotary_embedding_torch's einsum ('..., f -> ... f') doesn't convert, so the rotation uses cos/sin tables
  made once per sequence length (the model sees 1500 frames and 32/16/8 frequency bands).
- the head returns a dict; the wrapper returns (beat, downbeat).
"""
import json, os, sys
import numpy as np
import torch
from torch import nn
import coremltools as ct
from beat_this.inference import load_model
from beat_this.model import roformer

T, MELS = 1500, 128
out = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(out, exist_ok=True)
torch.manual_seed(0)

model = load_model("small0", device="cpu").eval()
ref = load_model("small0", device="cpu").eval()      # untouched, for the comparison


class FixedRotary(nn.Module):
    """rotate_queries_or_keys with the same angles as the original, from tables (no einsum)."""
    def __init__(self, rot):
        super().__init__()
        self.rot, self.tables = rot, {}

    def rotate_queries_or_keys(self, t):
        # int(): while tracing, a shape is a traced value that wouldn't find the tables made in the eager run
        n = int(t.shape[-2])
        if n not in self.tables:
            assert not torch.jit.is_tracing(), f"no rotary table for length {n}"
            with torch.no_grad():
                f = self.rot.forward(torch.arange(n, dtype=torch.float32))      # [n, dim], pairs repeated
            self.tables[n] = (f.cos(), f.sin())
        cos, sin = self.tables[n]
        d = cos.shape[-1]
        x, rest = t[..., :d], t[..., d:]
        p = x.reshape(*x.shape[:-1], d // 2, 2)
        half = torch.stack((-p[..., 1], p[..., 0]), dim=-1).reshape(x.shape)
        return torch.cat((x * cos + half * sin, rest), dim=-1)


shared = {}
for m in model.modules():
    if isinstance(m, roformer.Attention) and m.rotary_embed is not None:
        key = id(m.rotary_embed)
        shared.setdefault(key, FixedRotary(m.rotary_embed))
        m.rotary_embed = shared[key]


class Net(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, spect):
        y = self.m(spect)
        return y["beat"], y["downbeat"]


net = Net(model).eval()
x = torch.randn(1, T, MELS) * 0.5 + 1.0           # log1p(1000·mel) sits around 0-4
with torch.no_grad():
    a = ref(x)
    b = net(x)
diff = max(float((a["beat"] - b[0]).abs().max()), float((a["downbeat"] - b[1]).abs().max()))
print(f"patched vs original: largest logit difference {diff:.3g}")
assert diff < 1e-4, "the rotary replacement changed the model"

traced = torch.jit.trace(net, x)
with torch.no_grad():
    c = traced(x)
tdiff = max(float((a["beat"] - c[0]).abs().max()), float((a["downbeat"] - c[1]).abs().max()))
print(f"traced vs original: {tdiff:.3g}")

info = {"T": T, "mels": MELS, "patched_vs_original": diff, "traced_vs_original": tdiff,
        "torch": torch.__version__, "coremltools": ct.__version__, "numpy": np.__version__}
for prec, name in [(ct.precision.FLOAT16, "BeatThisSmall"), (ct.precision.FLOAT32, "BeatThisSmall32")]:
    ml = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                    compute_precision=prec,
                    inputs=[ct.TensorType(name="spect", shape=(1, T, MELS), dtype=np.float32)],
                    outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")])
    ml.short_description = "Beat This! small0 (CPJKU, MIT): beat and downbeat logits from a 30 s log-mel spectrogram"
    ml.license = "MIT (github.com/CPJKU/beat_this)"
    p = os.path.join(out, name + ".mlpackage")
    ml.save(p)
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs)
    info[name + "_bytes"] = size
    print(f"saved {p}: {size / 1e6:.1f} MB")

# a fixed input and the PyTorch answer, so the app's tests can check the Core ML model on a Mac
np.save(os.path.join(out, "check_input.npy"), x.numpy().astype(np.float32))
np.save(os.path.join(out, "check_beat.npy"), a["beat"].numpy().astype(np.float32))
np.save(os.path.join(out, "check_downbeat.npy"), a["downbeat"].numpy().astype(np.float32))
json.dump(info, open(os.path.join(out, "info.json"), "w"), indent=1)
print(json.dumps(info, indent=1))
