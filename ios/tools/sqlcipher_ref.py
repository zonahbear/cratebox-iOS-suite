# Reference SQLCipher 4 (default settings) page cipher, to check the Swift port against.
import hashlib, hmac, os, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
PAGE=4096; RES=80; SALT=16; HDR=b"SQLite format 3\x00"
def keys(passphrase, salt):
    k = hashlib.pbkdf2_hmac('sha512', passphrase.encode(), salt, 256000, 32)
    hsalt = bytes(b ^ 0x3a for b in salt)
    hk = hashlib.pbkdf2_hmac('sha512', k, hsalt, 2, 32)
    return k, hk
def decrypt(data, passphrase):
    salt = data[:16]; k, hk = keys(passphrase, salt)
    out = bytearray()
    for p in range(len(data)//PAGE):
        page = data[p*PAGE:(p+1)*PAGE]
        start = SALT if p == 0 else 0
        enc = page[start:PAGE-RES]; iv = page[PAGE-RES:PAGE-RES+16]; mac = page[PAGE-RES+16:PAGE]
        calc = hmac.new(hk, page[start:PAGE-RES+16] + (p+1).to_bytes(4,'little'), hashlib.sha512).digest()
        if calc != mac: raise ValueError(f"HMAC mismatch page {p+1}")
        d = Cipher(algorithms.AES(k), modes.CBC(iv)).decryptor()
        plain = d.update(enc) + d.finalize()
        if p == 0: plain = HDR + plain
        out += plain + bytes(RES)
    return bytes(out)
def encrypt(plain, passphrase, salt=None, ivs=None):
    salt = salt or os.urandom(16); k, hk = keys(passphrase, salt)
    out = bytearray()
    for p in range(len(plain)//PAGE):
        page = plain[p*PAGE:(p+1)*PAGE]
        start = SALT if p == 0 else 0
        iv = ivs[p] if ivs else os.urandom(16)
        e = Cipher(algorithms.AES(k), modes.CBC(iv)).encryptor()
        enc = e.update(page[start:PAGE-RES]) + e.finalize()
        body = enc + iv
        mac = hmac.new(hk, body + (p+1).to_bytes(4,'little'), hashlib.sha512).digest()
        out += (salt if p == 0 else b"") + body + mac
    return bytes(out)
