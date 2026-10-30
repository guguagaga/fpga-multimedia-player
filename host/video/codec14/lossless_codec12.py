"""Research C12HUF01 container. It cannot be played by the current FPGA bitstream.

Canonical Huffman tables are frozen independently of the input. Reconstruction
restores the original complete VID, including its header and zero padding.
"""
from pathlib import Path
import argparse,hashlib,json,mmap,struct,sys,time
R=Path(__file__).resolve().parent
sys.path.insert(0,str(Path(__file__).resolve().parent))
from repack_codec12_stream import unpack_frame

def contexts(data):
    pos=0
    while True:
        op=data[pos];yield 0,op;pos+=1
        if op==255:break
        if op in (133,135):yield 5,data[pos];pos+=1
        for i in range({128:1,129:2,131:64,132:4,133:1,134:4,135:2,136:4}[op]):
            yield 1,data[pos];yield 2,data[pos+1];pos+=2
        for i in range({129:8,136:16}.get(op,0)):
            yield 3 if op==129 else 4,data[pos];pos+=1
    assert pos==len(data)

class Codec:
    def __init__(self,lengths):
        assert len(lengths)==1536
        self.lengths=bytes(lengths);self.codes=[];self.trees=[]
        for c in range(6):
            table={};tree={};code=0;prior=0
            for length,symbol in sorted((lengths[c*256+s],s) for s in range(256)):
                if not 1<=length<=24:raise ValueError('Invalid Huffman length')
                code<<=length-prior
                if code>=1<<length:raise ValueError('Oversubscribed Huffman table')
                table[symbol]=(code,length);node=tree
                for i in range(length-1,0,-1):node=node.setdefault((code>>i)&1,{})
                node[code&1]=symbol;code+=1;prior=length
            self.codes.append(table);self.trees.append(tree)

    def encode(self,data):
        out=bytearray();bits=0;n=0
        for context,byte in contexts(data):
            code,length=self.codes[context][byte];bits=(bits<<length)|code;n+=length
            while n>=8:n-=8;out.append((bits>>n)&255)
            bits&=(1<<n)-1
        if n:out.append(bits<<(8-n))
        return bytes(out)

    def decode(self,data):
        bit=0;out=bytearray();blocks=0
        def read(context):
            nonlocal bit
            node=self.trees[context]
            while isinstance(node,dict):
                node=node[(data[bit//8]>>(7-bit%8))&1];bit+=1
            out.append(node);return node
        while blocks<14400:
            op=read(0);repeat=1
            if op in (133,135):
                extra=read(5)
                if op==133:repeat=extra+1
            for i in range({128:1,129:2,131:64,132:4,133:1,134:4,135:2,136:4}[op]):read(1);read(2)
            for i in range({129:8,136:16}.get(op,0)):read(3 if op==129 else 4)
            blocks+=repeat
        assert blocks==14400 and read(0)==255 and (bit+7)//8==len(data)
        if bit%8:assert data[-1]&((1<<(8-bit%8))-1)==0
        return bytes(out)

def main():
    a=argparse.ArgumentParser(description=__doc__);a.add_argument('--input',required=True,type=Path);a.add_argument('--output',required=True,type=Path);a.add_argument('--tables',type=Path,default=R/'context_entropy.json');args=a.parse_args()
    report_path=args.output.with_suffix('.json');restore=args.output.with_suffix('.restored.VID')
    for path in (args.output,report_path,restore):
        if path.exists():raise FileExistsError(path)
    spec=json.loads(args.tables.read_text());lengths=bytes(spec['codes'][c][str(s)]['length'] for c in range(6) for s in range(256));codec=Codec(lengths)
    rows=[];t=time.time()
    with args.input.open('rb') as inp,mmap.mmap(inp.fileno(),0,access=mmap.ACCESS_READ) as data,args.output.open('xb') as out:
        h=bytes(data[:512]);assert h[:6]==b'FPGV\x01\x0c';end,count=struct.unpack_from('<II',h,12)
        assert end<=len(data) and len(data)-end<512 and not any(data[end:])
        out.write(b'C12HUF01'+struct.pack('<Q',len(data))+h+lengths);pos=512
        for f in range(count):
            _,nextpos=unpack_frame(data,pos,end);raw=bytes(data[pos:nextpos]);packed=codec.encode(raw)
            out.write(struct.pack('<II',len(packed),len(raw))+packed)
            rows.append(dict(frame=f,original=len(raw),compressed=len(packed)+8));pos=nextpos
        assert pos==end
    # Independent file read, table rebuild and reconstruction; compare entire
    # restored file hash rather than just an encoder's in-memory token list.
    with args.output.open('rb') as inp,restore.open('xb') as out:
        assert inp.read(8)==b'C12HUF01';size=struct.unpack('<Q',inp.read(8))[0];h=inp.read(512)
        decoder=Codec(inp.read(1536));out.write(h);n=512
        for f in range(struct.unpack_from('<I',h,16)[0]):
            packed_size,raw_size=struct.unpack('<II',inp.read(8));raw=decoder.decode(inp.read(packed_size));assert len(raw)==raw_size
            out.write(raw);n+=len(raw)
        assert not inp.read(1) and n==struct.unpack_from('<I',h,12)[0] and 0<=size-n<512
        out.write(bytes(size-n))
    def sha(path):
        with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
    original_sha=sha(args.input);assert sha(restore)==original_sha
    mean=sum(r['compressed'] for r in rows)/len(rows);fps=struct.unpack_from('<H',h,10)[0]
    report=dict(passed=True,input=str(args.input),output=str(args.output),input_sha256=original_sha,restored_sha256=sha(restore),container_sha256=sha(args.output),frozen_tables_sha256=sha(args.tables),fps=fps,frames=len(rows),original_bytes=args.input.stat().st_size,compressed_bytes=args.output.stat().st_size,saving_percent=100*(1-args.output.stat().st_size/args.input.stat().st_size),mean_frame_bytes=mean,max_frame_bytes=max(r['compressed'] for r in rows),video_plus_pcm_mean_bytes_s=mean*fps+96000,rows=rows,seconds=time.time()-t,scope='Complete file reconstruction verified by SHA256. Same spatial quality as the supplied Codec12 video. Includes global table and frame-length overhead. Research container only: NOT compatible with v183; no FPGA entropy decoder, fresh STA or board qualification yet.')
    report_path.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='rows'},indent=2))

if __name__=='__main__':main()
