# Makes the OneLibrary test databases (CrateboxKitTests/Fixtures/onelibrary/) with real SQLCipher
# (pip install sqlcipher3-binary), so the Swift decryptor is tested against SQLCipher's own output.
# Tables and columns as in pyrekordbox's onelibrary models (MIT). Mirrors Fixtures/export.pdb's tracks and
# playlists; the "drift" copy disagrees with it on purpose (sync tests).
#   python3 ios/tools/onelibrary_fixture.py <passphrase> <out dir>
import sqlcipher3, sys, os, json
key, out = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
pdb = json.load(open(os.path.join(here, "../CrateboxKit/Tests/CrateboxKitTests/Fixtures/read.json")))
DDL = """
CREATE TABLE artist (artist_id INTEGER PRIMARY KEY, name VARCHAR, nameForSearch VARCHAR);
CREATE TABLE album (album_id INTEGER PRIMARY KEY, name VARCHAR, artist_id INTEGER, image_id INTEGER, isComplation INTEGER, nameForSearch VARCHAR);
CREATE TABLE genre (genre_id INTEGER PRIMARY KEY, name VARCHAR);
CREATE TABLE "key" (key_id INTEGER PRIMARY KEY, name VARCHAR);
CREATE TABLE label (label_id INTEGER PRIMARY KEY, name VARCHAR);
CREATE TABLE color (color_id INTEGER PRIMARY KEY, name VARCHAR);
CREATE TABLE content (content_id INTEGER PRIMARY KEY, title VARCHAR, titleForSearch VARCHAR, subtitle VARCHAR, bpmx100 INTEGER, length INTEGER,
  trackNo INTEGER, discNo INTEGER, artist_id_artist INTEGER, artist_id_remixer INTEGER, artist_id_originalArtist INTEGER, artist_id_composer INTEGER,
  artist_id_lyricist INTEGER, album_id INTEGER, genre_id INTEGER, label_id INTEGER, key_id INTEGER, color_id INTEGER, image_id INTEGER, djComment VARCHAR,
  rating INTEGER, releaseYear INTEGER, releaseDate DATETIME, dateCreated DATETIME, dateAdded DATETIME, path VARCHAR, fileName VARCHAR, fileSize INTEGER,
  fileType INTEGER, bitrate INTEGER, bitDepth INTEGER, samplingRate INTEGER, isrc VARCHAR, djPlayCount INTEGER, isHotCueAutoLoadOn INTEGER,
  isKuvoDeliverStatusOn INTEGER, kuvoDeliveryComment VARCHAR, masterDbId INTEGER, masterContentId INTEGER, analysisDataFilePath VARCHAR,
  analysedBits INTEGER, contentLink INTEGER, hasModified INTEGER, cueUpdateCount INTEGER, analysisDataUpdateCount INTEGER, informationUpdateCount INTEGER);
CREATE TABLE cue (cue_id INTEGER PRIMARY KEY, content_id INTEGER, kind INTEGER, colorTableIndex INTEGER, cueComment VARCHAR, isActiveLoop INTEGER,
  beatLoopNumerator INTEGER, beatLoopDenominator INTEGER, inUsec INTEGER, outUsec INTEGER, in150FramePerSec INTEGER, out150FramePerSec INTEGER,
  inMpegFrameNumber INTEGER, outMpegFrameNumber INTEGER, inMpegAbs INTEGER, outMpegAbs INTEGER, inDecodingStartFramePosition INTEGER,
  outDecodingStartFramePosition INTEGER, inFileOffsetInBlock INTEGER, outFileOffsetInBlock INTEGER, inNumberOfSampleInBlock INTEGER, outNumberOfSampleInBlock INTEGER);
CREATE TABLE playlist (playlist_id INTEGER PRIMARY KEY, sequenceNo INTEGER, name VARCHAR, image_id INTEGER, attribute INTEGER, playlist_id_parent INTEGER);
CREATE TABLE playlist_content (playlist_id INTEGER, content_id INTEGER, sequenceNo INTEGER, PRIMARY KEY (playlist_id, content_id));
CREATE TABLE property (deviceName VARCHAR PRIMARY KEY, dbVersion INTEGER, numberOfContents INTEGER, createdDate DATETIME, backGroundColorType INTEGER, myTagMasterDBID INTEGER);
"""
def make(path, drift):
    if os.path.exists(path): os.remove(path)
    c = sqlcipher3.connect(path)
    c.execute(f"PRAGMA key='{key}'")
    c.executescript(DDL)
    artists, keys = {}, {}
    for t in pdb["tracks"]:
        a = artists.setdefault(t["artist"], len(artists) + 1) if t["artist"] else None
        k = keys.setdefault(t["key"], len(keys) + 1) if t["key"] else None
        bpm = t["bpm"] + (1 if drift and t["id"] == 2 else 0)
        c.execute("INSERT INTO content (content_id, title, bpmx100, length, artist_id_artist, key_id, path, fileName, fileSize, samplingRate, bitDepth, bitrate, analysisDataFilePath, djComment, rating) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (t["id"], t["title"], int(round(bpm * 100)), t["duration"] * 1000, a, k, t["path"], t["filename"], t["size"], t["sampleRate"], 16, 0, t["anlzPath"], t["comment"], 0))
    for n, i in artists.items(): c.execute("INSERT INTO artist VALUES (?,?,?)", (i, n, n.lower()))
    for n, i in keys.items(): c.execute("INSERT INTO \"key\" VALUES (?,?)", (i, n))
    seq = {}
    for p in pdb["playlists"]:
        par = p["parent"]; seq[par] = seq.get(par, 0) + 1
        c.execute("INSERT INTO playlist VALUES (?,?,?,?,?,?)", (p["id"], seq[par], p["name"], None, 1 if p["folder"] else 0, par or None))
        tr = list(p["tracks"])
        if drift and p["name"] == "Sub Playlist": tr.reverse()
        for j, tid in enumerate(tr): c.execute("INSERT INTO playlist_content VALUES (?,?,?)", (p["id"], tid, j + 1))
    if drift:
        c.execute("INSERT INTO playlist VALUES (?,?,?,?,?,?)", (9, 3, "Only OneLibrary", None, 0, None))
        c.execute("INSERT INTO playlist_content VALUES (?,?,?)", (9, 5, 1))
    c.execute("INSERT INTO cue (cue_id, content_id, kind, inUsec, outUsec, colorTableIndex, cueComment) VALUES (1, 1, 1, 15000000, -1, 1, 'Drop')")
    c.execute("INSERT INTO cue (cue_id, content_id, kind, inUsec, outUsec, colorTableIndex, cueComment) VALUES (2, 1, 0, 500000, -1, 0, '')")
    c.execute("INSERT INTO property VALUES ('CRATEBOX TEST', 1000, 6, '2026-10-20', 0, 0)")
    c.commit(); c.close()
os.makedirs(out, exist_ok=True)
make(os.path.join(out, "exportLibrary.db"), False)
make(os.path.join(out, "exportLibrary-drift.db"), True)
