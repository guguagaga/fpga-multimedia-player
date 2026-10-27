#include <cstdio>
#include <cstring>
#include <cstdlib>
typedef unsigned long long U64;
static unsigned u32(const unsigned char*p){return p[0]|(p[1]<<8)|(p[2]<<16)|(unsigned(p[3])<<24);}
static void put32(unsigned char*p,unsigned v){for(int i=0;i<4;i++)p[i]=(v>>(8*i))&255;}
static int payload(int op){return op==128?2:op==129?12:op==131?128:op==132?8:0;}
static void flush(FILE*f,unsigned count,unsigned color){
 while(count){unsigned n=count>256?256:count;
  if(n==1)fputc(128,f);else{fputc(133,f);fputc(n-1,f);}
  fputc(color&255,f);fputc(color>>8,f);count-=n;
 }
}
int main(int argc,char**argv){
 if(argc!=4)return 2;bool verify=!strcmp(argv[1],"verify");
 FILE*a=fopen(argv[2],"rb");if(!a)return 3;unsigned char ah[512],bh[512],p[128],q[128];
 if(fread(ah,1,512,a)!=512||memcmp(ah,"FPGV\1",5)||ah[5]!=9)return 4;
 unsigned frames=u32(ah+16),blocks=(ah[6]|(ah[7]<<8))*(ah[8]|(ah[9]<<8))/64;
 FILE*b;
 if(verify){b=fopen(argv[3],"rb");if(!b||fread(bh,1,512,b)!=512||bh[5]!=10)return 5;}
 else{FILE*exists=fopen(argv[3],"rb");if(exists){fclose(exists);return 6;}b=fopen(argv[3],"wb");if(!b)return 7;memcpy(bh,ah,512);bh[5]=10;fwrite(bh,1,512,b);}
 U64 total=0;unsigned maximum=0;
 for(unsigned fi=0;fi<frames;fi++){
  long begin=ftell(b);unsigned count=0,color=0,remaining=0,runcolor=0;
  for(unsigned k=0;k<blocks;k++){
   int t=fgetc(a),n=payload(t);if(!n||fread(p,1,n,a)!=unsigned(n))return 8;
   if(verify){
    int nt;
    if(remaining){nt=128;q[0]=runcolor&255;q[1]=runcolor>>8;remaining--;}
    else{nt=fgetc(b);if(nt==133){remaining=fgetc(b);q[0]=fgetc(b);q[1]=fgetc(b);runcolor=q[0]|(q[1]<<8);nt=128;}else{int nn=payload(nt);if(!nn||fread(q,1,nn,b)!=unsigned(nn))return 9;}}
    if(nt!=t||memcmp(p,q,n))return 10;
   }else{
    unsigned c=p[0]|(p[1]<<8);
    if(t==128){if(count&&c!=color){flush(b,count,color);count=0;}count++;color=c;}
    else{flush(b,count,color);count=0;fputc(t,b);fwrite(p,1,n,b);}
   }
   total++;
  }
  if(fgetc(a)!=255)return 11;
  if(verify){if(remaining||fgetc(b)!=255)return 12;}
  else{flush(b,count,color);fputc(255,b);}
  unsigned framebytes=ftell(b)-begin;if(framebytes>maximum)maximum=framebytes;
 }
 unsigned declared=ftell(b);if(verify){if(declared!=u32(bh+12))return 13;}
 else{put32(bh+12,declared);while(ftell(b)%512)fputc(0,b);fseek(b,0,SEEK_SET);fwrite(bh,1,512,b);}
 fclose(a);fclose(b);
 printf("{\"passed\":true,\"operation\":\"%s\",\"frames\":%u,\"canonical_blocks_checked\":%llu,\"declared_bytes\":%u,\"max_frame_bytes\":%u}\n",verify?"verify":"encode",frames,total,declared,maximum);return 0;
}
