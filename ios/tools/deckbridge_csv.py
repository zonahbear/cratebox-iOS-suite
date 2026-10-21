# Writes deckbridge/Cratebox Deck Bridge.midi.csv: the same file DeckBridgeMap.rekordboxCSV() makes (a test checks
# they match). Run from the repo root: python3 ios/tools/deckbridge_csv.py
deckNote={'playPause':0x0B,'cue':0x0C,'sync':0x58,'keylock':0x1A,'quantize':0x35,'slip':0x40,'loopIn':0x10,'loopOut':0x11,'reloopExit':0x4D,'autoLoop':0x14,'loopHalf':0x12,'loopDouble':0x13,'headphoneCue':0x54,'hotCueMode':0x1B,'jumpToStart':0x48,'padFx1Mode':0x1E,'beatJumpMode':0x20,'padFx2Mode':0x6B}
deckCC={'tempo':0,'trim':4,'eqHigh':7,'eqMid':0x0B,'eqLow':0x0F,'channelFader':0x13}
G,FX=6,4
hx=lambda s,d:"%02X%02X"%(s,d)
rows=[]
four,pads="0,1,2,3","7,8,9,10"
for c,name,fn,opt,com in [('playPause','PlayPause','PlayPause','Fast;Blink=1000;Priority=50','Play/Pause'),('cue','Cue','Cue','Fast;Blink=500;Priority=50','Cue'),('jumpToStart','JumpToTrackStart','Cue+Shift','Fast;Priority=50','Jump to track start'),('sync','Sync','Sync','Blink=600','Sync On/Off'),('keylock','MasterTempo','MasterTempo','','Master Tempo (key lock) On/Off'),('quantize','Quantize','Quantize','','Quantize On/Off'),('slip','Slip','Slip','','Slip On/Off'),('loopIn','LoopIn','LoopIn','Fast','Loop in'),('loopOut','LoopOut','LoopOut','Fast','Loop out'),('reloopExit','ReloopExit','LoopOut+Shift','Fast','Reloop/Exit'),('autoLoop','4BeatLoop','4BeatLoop','Fast','Auto Loop On/Off'),('loopHalf','LoopHalf','LoopHalf','Fast','Loop 1/2'),('loopDouble','LoopDouble','LoopDouble','Fast','Loop x2'),('headphoneCue','HeadphoneCue','HeadphoneCue','','Headphone cue'),('hotCueMode','HotCue','HotCueMode','Fast','HOT CUE pad mode'),('beatJumpMode','BeatJump','BeatJumpMode','Fast','BEAT JUMP pad mode'),('padFx1Mode','PadFx1','PadFx1Mode','Fast','PAD FX 1 pad mode'),('padFx2Mode','PadFx2','PadFx2Mode','Fast','PAD FX 2 pad mode')]:
    code=hx(0x90,deckNote[c]); rows.append([name,fn,'Button',code,four,code,four,opt,com])
for k in range(8):
    rows.append([f"PAD{k+1}_HotCue",f"PAD{k+1}.HotCue.Call","Pad",hx(0x90,k),pads,hx(0x90,k),pads,"Fast",f"Hot cue {k+1}"])
    rows.append([f"PAD{k+1}_HotCue+Shift",f"PAD{k+1}.HotCue.Delete","Pad",hx(0x90,8+k),pads,"",",,,","Fast",f"Delete hot cue {k+1}"])
for base,name,label in [(0x20,'BeatJump','Beat jump'),(0x10,'PadFx1','Pad FX 1'),(0x30,'PadFx2','Pad FX 2')]:
    for k in range(8):
        code=hx(0x90,base+k); rows.append([f"PAD{k+1}_{name}",f"PAD{k+1}.{name}","Pad",code,pads,code,pads,"Fast",f"{label} pad {k+1}"])
for c,name,com in [('tempo','TempoSlider','Tempo'),('trim','Gain','Trim'),('eqHigh','EQHigh','EQ high'),('eqMid','EQMid','EQ mid'),('eqLow','EQLow','EQ low'),('channelFader','ChannelFader','Channel fader')]:
    rows.append([name,name,'KnobSliderHiRes',hx(0xB0,deckCC[c]),four,'',',,,','Fast',com])
rows.append(["JogScratch","JogScratch","JogRotate",hx(0xB0,0x22),four,"",",,,","","Jog: scratch (touching)"])
rows.append(["JogPitchBend","JogPitchBend","JogRotate",hx(0xB0,0x23),four,"",",,,","","Jog: pitch bend (edge)"])
rows.append(["JogTouch","JogTouch","JogTouch",hx(0x90,0x36),four,"",",,,","","Jog: touch"])
for d in range(4):
    rows.append([f"CFXParameterCH{d+1}",f"CFXParameterCH{d+1}","KnobSliderHiRes",hx(0xB0|G,0x17+d),",,,","",",,,","Fast",f"CH{d+1} filter (Sound Color FX)"])
    rows.append([f"FX1Assign.CH{d+1}","","Button",hx(0x90|FX,0x10+d),",,,","",",,,","",f"Beat FX on CH{d+1}"])
rows.append(["CFX4On","CFX4On","Button",hx(0x90|G,3),",,,",hx(0x90|G,3),",,,","Fast","Sound Color FX: FILTER"])
rows.append(["CrossFader","CrossFader","KnobSliderHiRes",hx(0xB0|G,0x1F),",,,","",",,,","Fast","Crossfader"])
rows.append(["Browse","Browse","Rotary",hx(0xB0|G,0x40),",,,","",",,,","","Browse"])
rows.append(["Back","Back","Button",hx(0x90|G,0x65),",,,","",",,,","","Library back"])
rows.append(["Load","Load","Button","",",".join(hx(0x90|G,0x46+d) for d in range(4)),"",",,,","","Load to deck"])
rows.append(["FX1-1","FX1-1","KnobSliderHiRes",hx(0xB0|FX,2),",,,","",",,,","","Beat FX depth"])
rows.append(["FX1-1On","FX1-1On","Button",hx(0x90|FX,0x47),",,,",hx(0x90|FX,0x47),",,,","","Beat FX on/off"])
rows.append(["FX1-1Select","FX1-1Select","Button",hx(0x90|FX,0x63),",,,","",",,,","","Beat FX select"])
rows.append(["FX1BeatDown","FX1BeatDown","Button",hx(0x90|FX,0x4A),",,,","",",,,","","Beat FX beat -"])
rows.append(["FX1BeatUp","FX1BeatUp","Button",hx(0x90|FX,0x4B),",,,","",",,,","","Beat FX beat +"])
lines=["@file,1,Cratebox Deck Bridge","#name,function,type,input,deck1,deck2,deck3,deck4,output,deck1,deck2,deck3,deck4,option,comment"]
for r in rows:
    r[6]=r[6] or ",,,"; lines.append(",".join(r))
for l in lines[1:]: assert l.count(",")==14, l
open("deckbridge/Cratebox Deck Bridge.midi.csv","w",newline="").write("\r\n".join(lines)+"\r\n")
print(len(lines),"lines")
