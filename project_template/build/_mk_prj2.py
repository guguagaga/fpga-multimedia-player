import re, os, sys, datetime
PROJ = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "td_project"))
AL   = os.path.join(PROJ, "HDMI1.4b_Transmitter_v1.0.al")
RUN  = sys.argv[1]
OUT  = os.path.join(RUN, "HDMI1.4b_Transmitter_v1.0.prj")

rel_to_parent = os.path.relpath(os.path.dirname(PROJ), RUN).replace("\\", "/") + "/"
rel_to_proj   = os.path.relpath(PROJ, RUN).replace("\\", "/") + "/"

def to_run(p):
    return os.path.relpath(os.path.normpath(os.path.join(PROJ, p)), RUN).replace("\\", "/")

raw = open(AL, "rb").read().decode("utf-8")
raw, n = re.subn(r'<File Path="([^"]+)">', lambda m: '<File Path="%s">' % to_run(m.group(1)), raw)
stamp = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
raw = raw.replace('<Project Version="3" Minor="2" Path=',
                  '<Project Version="3" Minor="2" RunTime="%s" Path=' % stamp, 1)
raw = re.sub(r'(<Project Version="3" Minor="2" RunTime="[^"]*") Path="[^"]*"', r"\1", raw, count=1)
os.makedirs(RUN, exist_ok=True)
open(OUT, "wb").write(raw.encode("utf-8"))

paths = re.findall(r'<File Path="([^"]+)">', raw)
bad = [p for p in paths
       if not os.path.isfile(os.path.normpath(os.path.join(RUN, p.replace("/", os.sep))))]
print("%s: rewrote %d, resolvable %d/%d" % (os.path.basename(RUN), n, len(paths)-len(bad), len(paths)))
for p in bad:
    print("  MISSING", p)

if bad: sys.exit(1)
