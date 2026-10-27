#include <cstdio>
#include <cstring>
#include <cstdlib>
int main(int argc,char**argv){
 if(argc!=3)return 2;FILE*a=fopen(argv[1],"rb"),*b=fopen(argv[2],"rb");if(!a||!b)return 3;
 unsigned char ha[512],hb[512];if(fread(ha,1,512,a)!=512||fread(hb,1,512,b)!=512||memcmp(ha,hb,512)||ha[5]!=9)return 4;
 unsigned frames=ha[16]|(ha[17]<<8)|(ha[18]<<16)|(ha[19]<<24);unsigned long long blocks=0,changed=0,raw=0,pal=0;
 for(unsigned f=0;f<frames;f++){
  for(int k=0;k<14400;k++){
   int x=fgetc(a),y=fgetc(b);if(x!=y)return 5;int n=x==128?2:x==129?12:x==132?8:x==131?128:-1;if(n<0)return 6;
   unsigned char p[128],q[128];if(fread(p,1,n,a)!=(unsigned)n||fread(q,1,n,b)!=(unsigned)n)return 7;
   if(x==129){if(memcmp(p+4,q+4,8))return 8;pal++;}
   if(x==131){if(memcmp(p,q,128))return 9;raw++;}
   if(memcmp(p,q,n))changed++;blocks++;
  }
  if(fgetc(a)!=255||fgetc(b)!=255)return 10;
 }
 int x,y;do{x=fgetc(a);y=fgetc(b);if(x!=y)return 11;if(x>0)return 12;}while(x!=EOF);
 printf("{\"passed\":true,\"frames\":%u,\"blocks_checked\":%llu,\"changed_color_blocks\":%llu,\"raw_blocks_identical\":%llu,\"pal_masks_identical\":%llu,\"scope\":\"Identical headers,token modes,frame boundaries,RAW payloads,PAL masks and padding; only representative colors changed.\"}\n",frames,blocks,changed,raw,pal);return 0;
}
