"""Run portable playlist regressions against a restored FPGA project."""
from pathlib import Path
import argparse,datetime,hashlib,json,subprocess,time

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project',type=Path,required=True)
    p.add_argument('--test',choices=['controls','eof','video','audio'],required=True)
    p.add_argument('--benches',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--td-root',type=Path,default=Path('D:/TD3'))
    p.add_argument('--modelsim',default='E:/modelsim/modelsim_ase/win32aloem/vsim.exe')
    p.add_argument('--iverilog-root',type=Path,default=Path('C:/iverilog/bin'))
    a=p.parse_args();project=a.project.resolve();bench=a.benches.resolve();out=a.output.resolve()
    cases={
      'controls':('tb_playlist.sv',['rtl/video_catalog.v','rtl/video_playlist_ctrl.v'],'PASS catalog pairing'),
      'eof':('tb_eof_cdc.sv',['rtl/video_eof_guard.v','rtl/av_sample_sync.v'],'PASS actual 90.9MHz/12.288MHz EOF CDC'),
      'video':('tb_video_switch.sv', ['rtl/'+n for n in ['video_playlist_ctrl.v','video_eof_guard.v','av_sample_sync.v','video_player.v','video_byte_ram.v','video_codec8_raster.v','codec12_block_decoder_experimental.v','gradient_block_experimental.v','fat32_sector_mapper.v','rgb565_pair_pack.v']]+['user_source/hdl_source/sd_arbiter.v','user_source/hdl_source/SD/frame_fifo_write.v'],'PASS actual decoder/arbiter/fragmented FAT playlist'),
      'audio':('audio_playlist.v',['rtl/video_playlist_ctrl.v','rtl/av_sample_sync.v','rtl/volume_control.v']+['user_source/hdl_source/'+n for n in ['media_player.v','compressed_audio_reader.v','sector_byte_source.v','qoa_stream.v','ima_stream.v','audio_transition.v','async_fifo.v','wav_sample_builder.v','i2s_transmitter.v']],'PASS real audio playlist')}
    tb,names,marker=cases[a.test];files=[bench/tb]+[project/n for n in names]
    if a.test in ['video','audio']:files += [a.td_root/'sim_release/eg4'/n for n in ['eg_phy_bram32k.v','eg_phy_glbl.v']]
    sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
    snapshot={str(f):sha(f) for f in files};out.mkdir(parents=True,exist_ok=False);started=time.time()
    if a.test in ['controls','eof']:
        c=subprocess.run([str(a.iverilog_root/'iverilog.exe'),'-g2012','-s','tb','-o',str(out/'sim.vvp'),*map(str,files)],capture_output=True,text=True)
        (out/'compile.log').write_text(c.stdout+c.stderr,encoding='utf-8');assert c.returncode==0,c.stderr
        command=[str(a.iverilog_root/'vvp.exe'),str(out/'sim.vvp')]
    else:
        flow='onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.as_posix()+'}' for f in files)+'\nvsim work.tb work.glbl\nrun -all\nquit -code 0\n'
        (out/'run.do').write_text(flow,encoding='utf-8');command=[a.modelsim,'-c','-do','run.do']
    with(out/'console.log').open('w',encoding='utf-8')as log:c=subprocess.run(command,cwd=out,stdout=log,stderr=subprocess.STDOUT)
    text=(out/'console.log').read_text(encoding='utf-8',errors='replace')
    passed=c.returncode==0 and marker in text and '** Fatal'not in text and '** Error'not in text
    assert snapshot=={str(f):sha(f)for f in files},'source changed while testing'
    report=dict(passed=passed,test=a.test,seconds=time.time()-started,source_sha256=snapshot,output=text[-6000:])
    (out/'result.json').write_text(json.dumps(report,indent=2),encoding='utf-8');print('PASS'if passed else'FAIL',a.test,out)
    raise SystemExit(0 if passed else 1)

if __name__=='__main__':main()
