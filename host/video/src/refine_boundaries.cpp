#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cmath>
#include <algorithm>
#include <fcntl.h>
#include <io.h>
typedef unsigned short U16;typedef unsigned char U8;
struct C {double a[3]; C(){a[0]=a[1]=a[2]=0;} };
struct Region {C original,color,next;double pixels,den;int offset;Region():pixels(0),den(0),offset(0){}};
C unpack(U16 p){C c;c.a[0]=p>>11;c.a[1]=(p>>5)&63;c.a[2]=p&31;return c;}
U16 pack(C c){int v[3];for(int k=0;k<3;k++)v[k]=std::max(0,std::min(k==1?63:31,(int)floor(c.a[k]+0.5)));return(v[0]<<11)|(v[1]<<5)|v[2];}
int main(int argc,char**argv){
 if(argc!=4)return 2;double weight=atof(argv[3]);FILE*in=fopen(argv[1],"rb"),*out=fopen(argv[2],"wb");if(!in||!out)return 3;
 _setmode(_fileno(stdin),_O_BINARY);U8 head[512];if(fread(head,1,512,in)!=512||head[5]!=9)return 4;fwrite(head,1,512,out);
 std::vector<U16>raw(921600);std::vector<C>original(921600),decoded(921600);std::vector<int>ids(921600);unsigned frames=0;unsigned long long bytes=512;
 while(fread(&raw[0],2,921600,stdin)==921600){
  std::vector<U8>tokens;std::vector<Region>regions;
  for(int y=0;y<720;y++)for(int x=0;x<1280;x++)original[y*1280+x]=unpack(raw[(719-y)*1280+x]);
  for(int block=0;block<14400;block++){
   int op=fgetc(in),sz=op==128?2:op==129?12:op==132?8:op==131?128:-1;if(sz<0)return 5;
   int start=tokens.size();tokens.push_back(op);for(int n=0;n<sz;n++){int ch=fgetc(in);if(ch<0)return 6;tokens.push_back(ch);}
   int first=regions.size(),nc=op==128?1:op==129?2:op==132?4:0;
   for(int n=0;n<nc;n++){Region reg;reg.offset=start+1+2*n;reg.color=unpack(tokens[reg.offset]|(tokens[reg.offset+1]<<8));regions.push_back(reg);}
   for(int y=0;y<8;y++)for(int x=0;x<8;x++){
    int loc=(block/160*8+y)*1280+block%160*8+x;int idx=y*8+x;
    if(op==131){ids[loc]=-1;decoded[loc]=unpack(tokens[start+1+2*idx]|(tokens[start+2+2*idx]<<8));}
    else{int p=op==128?0:op==129?((tokens[start+5+y]>>x)&1):(y/4)*2+x/4;int id=first+p;ids[loc]=id;
     regions[id].pixels++;for(int k=0;k<3;k++)regions[id].original.a[k]+=original[loc].a[k];}
   }
  }
  if(fgetc(in)!=255)return 7;tokens.push_back(255);
  // Fixed modes/masks, jointly fit representative colors across 4/8-pixel seams.
  // Objective = source pixel SSE + weight * residual-gradient SSE at grid edges.
  // No new token, dimensions, orientation, decoder logic or per-frame bytes.
  for(int it=0;it<8;it++){
   for(unsigned n=0;n<regions.size();n++){regions[n].next=regions[n].original;regions[n].den=regions[n].pixels;}
   for(int i=0;i<921600;i++)if(ids[i]>=0)decoded[i]=regions[ids[i]].color;
   for(int y=0;y<720;y++)for(int x=0;x<1280;x++){
    int i=y*1280+x;
    for(int axis=0;axis<2;axis++){
     if(axis?(y==0||y%4!=0):(x==0||x%4!=0))continue;
     int j=axis?i-1280:i-1;int a=ids[i],b=ids[j];if(a==b)continue;
     if(a>=0){regions[a].den+=weight;for(int k=0;k<3;k++)regions[a].next.a[k]+=weight*(original[i].a[k]-original[j].a[k]+decoded[j].a[k]);}
     if(b>=0){regions[b].den+=weight;for(int k=0;k<3;k++)regions[b].next.a[k]+=weight*(original[j].a[k]-original[i].a[k]+decoded[i].a[k]);}
    }
   }
   for(unsigned n=0;n<regions.size();n++)if(regions[n].den>0){for(int k=0;k<3;k++)regions[n].next.a[k]/=regions[n].den;regions[n].color=regions[n].next;}
  }
  for(unsigned n=0;n<regions.size();n++){U16 c=pack(regions[n].color);tokens[regions[n].offset]=c&255;tokens[regions[n].offset+1]=c>>8;}
  fwrite(&tokens[0],1,tokens.size(),out);bytes+=tokens.size();frames++;if(frames%150==0){fprintf(stderr,"REFINED frames=%u\n",frames);fflush(stderr);}
 }
 U8 zero[512]={0};fwrite(zero,1,(512-bytes%512)%512,out);fclose(in);fclose(out);fprintf(stderr,"DONE refined=%u bytes=%llu\n",frames,bytes);return 0;
}
