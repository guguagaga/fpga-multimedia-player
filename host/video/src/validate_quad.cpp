#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cstring>
#include <cmath>
#include <fcntl.h>
#include <io.h>
typedef unsigned char U8;typedef unsigned short U16;
unsigned u32(const U8*p){return (unsigned)p[0]|((unsigned)p[1]<<8)|((unsigned)p[2]<<16)|((unsigned)p[3]<<24);}
struct Decoder{
 FILE*f;unsigned declared,frames,pos,index;std::vector<U8>buf;bool budget;
 Decoder(const char*path,bool cap):pos(512),index(0),budget(cap){f=fopen(path,"rb");if(!f)exit(2);U8 h[512];if(fread(h,1,512,f)!=512)exit(3);if((memcmp(h,"FPGV\1",5)||(h[5]!=8&&h[5]!=9))||h[6]!=32||h[7]!=3||h[8]!=88||h[9]!=2||h[10]!=15||h[11]!=0)exit(4);declared=u32(h+12);frames=u32(h+16);}
 int byte(){if(pos>=declared){fprintf(stderr,"READ PAST DECLARED %u\n",pos);exit(5);}int b=fgetc(f);if(b==EOF)exit(6);pos++;return b;}
 U16 word(){int a=byte(),b=byte();return a|(b<<8);}
 unsigned decode(std::vector<U16>&pix){unsigned start=pos;for(int k=0;k<7500;k++){int t=byte();U16 p[64];if(t==128){U16 a=word();for(int i=0;i<64;i++)p[i]=a;}else if(t==129){U16 a=word(),b=word();for(int y=0;y<8;y++){int bits=byte();for(int x=0;x<8;x++)p[y*8+x]=(bits>>x)&1?b:a;}}else if(t==132){U16 color[4];for(int i=0;i<4;i++)color[i]=word();for(int y=0;y<8;y++)for(int x=0;x<8;x++)p[y*8+x]=color[(y/4)*2+x/4];}else if(t==131){for(int i=0;i<64;i++)p[i]=word();}else{fprintf(stderr,"TOKEN ERROR %d frame %u block %d\n",t,index,k);exit(7);}int by=k/100,bx=k%100;for(int y=0;y<8;y++)for(int x=0;x<8;x++)pix[(by*8+y)*800+bx*8+x]=p[y*8+x];}if(byte()!=255)exit(8);unsigned size=pos-start;if(budget&&size>45000)exit(9);index++;return size;}
 void finish(){if(index!=frames||pos!=declared)exit(10);int b,n=0;while((b=fgetc(f))!=EOF){if(b!=0)exit(11);n++;}if(n>511||(pos+n)%512)exit(12);fclose(f);}
};
int red(U16 v){return ((v>>11)<<3)|(v>>13);}int green(U16 v){return (((v>>5)&63)<<2)|((v>>9)&3);}int blue(U16 v){return ((v&31)<<3)|((v>>2)&7);}
int main(int argc,char**argv){if(argc!=4)return 1;_setmode(_fileno(stdin),_O_BINARY);Decoder a(argv[1],true),old(argv[2],false);if(a.frames!=6330||old.frames!=a.frames)exit(13);FILE*csv=fopen(argv[3],"w");fprintf(csv,"frame,new_bytes,old_bytes,new_sse,old_sse,new_abs,old_abs\n");std::vector<U16>raw(480000),pix(480000),prev(480000);double se=0,ose=0,ae=0,oae=0;unsigned maxsz=0,worse=0;unsigned long long n=0;
 for(unsigned f=0;f<a.frames;f++){if(fread(&raw[0],2,480000,stdin)!=480000)exit(14);unsigned size=a.decode(pix),osize=old.decode(prev);if(size>maxsz)maxsz=size;double fs=0,fo=0,fa=0,oa=0;
  for(int y=75;y<525;y++)for(int x=0;x<800;x++){int si=y*800+x,di=(599-y)*800+x;int d[3]={red(raw[si])-red(pix[di]),green(raw[si])-green(pix[di]),blue(raw[si])-blue(pix[di])};int o[3]={red(raw[si])-red(prev[di]),green(raw[si])-green(prev[di]),blue(raw[si])-blue(prev[di])};for(int c=0;c<3;c++){fs+=d[c]*d[c];fo+=o[c]*o[c];fa+=abs(d[c]);oa+=abs(o[c]);}}
  if(fs>fo)worse++;se+=fs;ose+=fo;ae+=fa;oae+=oa;n+=800ULL*450*3;fprintf(csv,"%u,%u,%u,%.0f,%.0f,%.0f,%.0f\n",f,size,osize,fs,fo,fa,oa);if(f%1500==0){fprintf(stderr,"CHECKED frame %u\n",f);fflush(stderr);}
 }if(fgetc(stdin)!=EOF)exit(15);a.finish();old.finish();fclose(csv);
 printf("{\"passed\":true,\"frames\":%u,\"decoded_pixels\":3038400000,\"quality_active_pixels\":2278800000,\"max_frame_bytes\":%u,\"new_psnr\":%.6f,\"old_psnr\":%.6f,\"new_mae\":%.6f,\"old_mae\":%.6f,\"frames_with_higher_sse\":%u,\"orientation\":\"source horizontal unchanged, vertical reversed for existing writer; same as previous card\"}\n",a.frames,maxsz,10*log10(255.0*255.0*n/se),10*log10(255.0*255.0*n/ose),ae/n,oae/n,worse);return 0;}
