from pathlib import Path
import subprocess,sys
r=Path(__file__).resolve().parents[2];d=r/'verification/fat32';out=d/'mapper.vvp'
subprocess.run(['iverilog','-g2012','-s','tb','-o',str(out),str(d/'tb_mapper.v'),str(r/'rtl/storage/fat32_sector_mapper.v')],check=True)
subprocess.run(['vvp',str(out)],check=True)
