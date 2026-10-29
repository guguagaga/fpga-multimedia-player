#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <cstring>
#include <queue>
#include <cmath>
#include <fcntl.h>
#include <io.h>
typedef unsigned short U16; typedef unsigned char U8;
int solid_limit=1000,pal_limit=8000;
int frame_budget=45000;
int quad_enable=0;
int r(U16 x){return x>>11;} int g(U16 x){return(x>>5)&63;} int b(U16 x){return x&31;}
int dist(U16 a,U16 c){int x=r(a)-r(c),y=g(a)-g(c),z=b(a)-b(c);return x*x+y*y+z*z;}
bool lum(U16 a,U16 c){return 2*r(a)+3*g(a)+b(a)<2*r(c)+3*g(c)+b(c);}
void word(std::vector<U8>&o,U16 v){o.push_back(v&255);o.push_back(v>>8);}
void block(U16 *px,std::vector<U8>&o){
 bool same=true;int sr=0,sg=0,sb=0;for(int i=0;i<64;i++){same &= px[i]==px[0];sr+=r(px[i]);sg+=g(px[i]);sb+=b(px[i]);}
 U16 mid=(sr/64<<11)|(sg/64<<5)|(sb/64);int se=0;for(int i=0;i<64;i++)se+=dist(px[i],mid);
 if(same||se<=solid_limit){o.push_back(128);word(o,same?px[0]:mid);return;}
 std::vector<U16> unique(px,px+64);std::sort(unique.begin(),unique.end());unique.erase(std::unique(unique.begin(),unique.end()),unique.end());U16 pal[2];
 if(unique.size()<=2){pal[0]=unique[0];pal[1]=unique.back();}
 else{std::vector<U16> sorted(px,px+64);std::stable_sort(sorted.begin(),sorted.end(),lum);pal[0]=sorted[16];pal[1]=sorted[48];
 for(int it=0;it<2;it++){int rr[2]={0,0},gg[2]={0,0},bb[2]={0,0},n[2]={0,0};for(int i=0;i<64;i++){int k=dist(px[i],pal[1])<dist(px[i],pal[0]);n[k]++;rr[k]+=r(px[i]);gg[k]+=g(px[i]);bb[k]+=b(px[i]);}for(int k=0;k<2;k++)if(n[k])pal[k]=(rr[k]/n[k]<<11)|(gg[k]/n[k]<<5)|(bb[k]/n[k]);}}
 U8 ix[8]={0};int error=0;for(int i=0;i<64;i++){int d0=dist(px[i],pal[0]),d1=dist(px[i],pal[1]),k=d1<d0;error+=k?d1:d0;ix[i/8]|=k<<(i%8);}
 if(error<=pal_limit){o.push_back(129);word(o,pal[0]);word(o,pal[1]);o.insert(o.end(),ix,ix+8);}else{o.push_back(131);for(int i=0;i<64;i++)word(o,px[i]);}
}
void put32(U8*p,unsigned v){for(int i=0;i<4;i++)p[i]=(v>>(8*i))&255;}
int visual_dist(U16 a,U16 c){int x=r(a)-r(c),y=g(a)-g(c),z=b(a)-b(c);return 4*x*x+y*y+4*z*z;}

U16 gradient_pixel(const std::vector<U8>&t,int x,int y){
 int weights[4]={(8-x)*(8-y),x*(8-y),(8-x)*y,x*y},rr=32,gg=32,bb=32;
 for(int k=0;k<4;k++){U16 c=t[1+2*k]|(t[2+2*k]<<8);rr+=weights[k]*r(c);gg+=weights[k]*g(c);bb+=weights[k]*b(c);}
 return((rr>>6)<<11)|((gg>>6)<<5)|(bb>>6);
}

int redesign_flags=0;
int edge_ax[8]={1,0,1,1,2,2,1,1},edge_ay[8]={0,1,1,-1,1,-1,2,-2};
int projection(int dir,int x,int y){int a=edge_ax[dir],b=edge_ay[dir];return a*x+b*y-(b<0?b*7:0);}
U16 getword(const std::vector<U8>&t,int i){return t[i]|(t[i+1]<<8);}
U16 redesigned_pixel(const std::vector<U8>&t,int x,int y){
 if(t[0]==135){int dir=t[1]>>5,threshold=t[1]&31;return getword(t,projection(dir,x,y)>=threshold?4:2);}
 int i=y*8+x;return getword(t,1+2*((t[9+i/4]>>(2*(i%4)))&3));
}

int token_error(const U16*px,const std::vector<U8>&t){int sum=0;if(t[0]==135||t[0]==136){for(int i=0;i<64;i++)sum+=visual_dist(px[i],redesigned_pixel(t,i%8,7-i/8));return sum;}if(t[0]==131)return 0;if(t[0]==134){for(int i=0;i<64;i++)sum+=visual_dist(px[i],gradient_pixel(t,i%8,7-i/8));return sum;}U16 a=t[1]|(t[2]<<8),b=t[0]==129?(t[3]|(t[4]<<8)):a;for(int i=0;i<64;i++){int bit=t[0]==129?((t[5+i/8]>>(i%8))&1):0;sum+=visual_dist(px[i],bit?b:a);}return sum;}
std::vector<U8> best_pal2(U16*px,const std::vector<U8>&initial){
 int best=0x7fffffff;std::vector<U8>result;
 if(initial[0]==129){result=initial;best=token_error(px,initial);}
 U16 seeds[10][2];std::vector<U16> sorted(px,px+64);std::stable_sort(sorted.begin(),sorted.end(),lum);
 seeds[0][0]=sorted[16];seeds[0][1]=sorted[48];seeds[1][0]=sorted[0];seeds[1][1]=sorted[63];
 for(int ch=0;ch<3;ch++){int imin=0,imax=0;for(int i=1;i<64;i++){int v=ch==0?r(px[i]):ch==1?g(px[i]):b(px[i]);int mn=ch==0?r(px[imin]):ch==1?g(px[imin]):b(px[imin]);int mx=ch==0?r(px[imax]):ch==1?g(px[imax]):b(px[imax]);if(v<mn)imin=i;if(v>mx)imax=i;}seeds[2+ch][0]=px[imin];seeds[2+ch][1]=px[imax];}
 for(int trial=0;trial<5;trial++){
  U16 pal[2]={seeds[trial][0],seeds[trial][1]};
  for(int it=0;it<8;it++){int rr[2]={0},gg[2]={0},bb[2]={0},n[2]={0};
   for(int i=0;i<64;i++){int k=visual_dist(px[i],pal[1])<visual_dist(px[i],pal[0]);n[k]++;rr[k]+=r(px[i]);gg[k]+=g(px[i]);bb[k]+=b(px[i]);}
   U16 next[2]={pal[0],pal[1]};for(int k=0;k<2;k++)if(n[k])next[k]=((rr[k]+n[k]/2)/n[k]<<11)|((gg[k]+n[k]/2)/n[k]<<5)|(bb[k]+n[k]/2)/n[k];
   bool done=next[0]==pal[0]&&next[1]==pal[1];pal[0]=next[0];pal[1]=next[1];if(done)break;
  }
  std::vector<U8>t;t.push_back(129);word(t,pal[0]);word(t,pal[1]);U8 bits[8]={0};for(int i=0;i<64;i++){int k=visual_dist(px[i],pal[1])<visual_dist(px[i],pal[0]);bits[i/8]|=k<<(i%8);}t.insert(t.end(),bits,bits+8);
  int error=token_error(px,t);if(error<best){best=error;result=t;}
 }
 return result;
}
struct Point {int cost,error,kind;std::vector<U8>tok;};
struct Upgrade {int index,gain,cost,stage;};
struct LowerGain {bool operator()(const Upgrade&a,const Upgrade&b)const{long long l=(long long)a.gain*b.cost,r=(long long)b.gain*a.cost;return l<r||(l==r&&a.index>b.index);}};
Point make_quad(const U16*px){
 Point q;q.cost=9;q.kind=1;q.tok.push_back(132);q.error=0;
 for(int qy=0;qy<2;qy++)for(int qx=0;qx<2;qx++){
  int sr=0,sg=0,sb=0;for(int y=0;y<4;y++)for(int x=0;x<4;x++){U16 v=px[(qy*4+y)*8+qx*4+x];sr+=r(v);sg+=g(v);sb+=b(v);}
  U16 value=((sr+8)/16<<11)|((sg+8)/16<<5)|(sb+8)/16;word(q.tok,value);
  for(int y=0;y<4;y++)for(int x=0;x<4;x++)q.error+=visual_dist(px[(qy*4+y)*8+qx*4+x],value);
 }return q;
}

Point make_gradient(const U16*px){
 Point p;p.cost=9;p.kind=4;p.tok.push_back(134);
 for(int cy=0;cy<2;cy++)for(int cx=0;cx<2;cx++){
  double sums[3]={0,0,0};
  for(int y=0;y<8;y++)for(int x=0;x<8;x++){
   double wx=cx?(3.0*x-7)/28:(5.0-x)/12,wy=cy?(3.0*y-7)/28:(5.0-y)/12;
   U16 c=px[(7-y)*8+x];sums[0]+=wx*wy*r(c);sums[1]+=wx*wy*g(c);sums[2]+=wx*wy*b(c);
  }
  int v[3];for(int k=0;k<3;k++)v[k]=std::max(0,std::min(k==1?63:31,(int)floor(sums[k]+0.5)));
  word(p.tok,(v[0]<<11)|(v[1]<<5)|v[2]);
 }
 p.error=token_error(px,p.tok);return p;
}

// 6-byte straight-edge block: opcode, 3-bit normal + 5-bit threshold, two RGB565 colors.
Point make_edge(const U16*px){
 Point best;best.cost=6;best.kind=5;best.error=0x7fffffff;
 for(int dir=0;dir<8;dir++){
  int sums[32][3]={0},n[32]={0};int total[3]={0};
  for(int y=0;y<8;y++)for(int x=0;x<8;x++){
   U16 c=px[(7-y)*8+x];int z=projection(dir,x,y);n[z]++;sums[z][0]+=r(c);sums[z][1]+=g(c);sums[z][2]+=b(c);total[0]+=r(c);total[1]+=g(c);total[2]+=b(c);
  }
  int low[3]={0},count=0;
  for(int cut=1;cut<32;cut++){
   count+=n[cut-1];for(int c=0;c<3;c++)low[c]+=sums[cut-1][c];if(count==0||count==64)continue;
   U16 colors[2];for(int k=0;k<2;k++){int nn=k?64-count:count;int v[3];for(int c=0;c<3;c++)v[c]=((k?total[c]-low[c]:low[c])+nn/2)/nn;colors[k]=(v[0]<<11)|(v[1]<<5)|v[2];}
   std::vector<U8>t;t.push_back(135);t.push_back((dir<<5)|cut);word(t,colors[0]);word(t,colors[1]);int err=token_error(px,t);
   if(err<best.error){best.error=err;best.tok=t;}
  }
 }return best;
}
// 25-byte four-color block: opcode, four RGB565 colors and 64 two-bit indices.
Point make_pal4(const U16*px){
 Point best;best.cost=25;best.kind=6;best.error=0x7fffffff;
 std::vector<U16> sorted(px,px+64);std::stable_sort(sorted.begin(),sorted.end(),lum);
 for(int trial=0;trial<2;trial++){
  U16 pal[4];for(int k=0;k<4;k++)pal[k]=sorted[8+16*k];
  if(trial){pal[0]=sorted[32];for(int k=1;k<4;k++){int worst=-1;for(int i=0;i<64;i++){int near=0x7fffffff;for(int j=0;j<k;j++)near=std::min(near,visual_dist(px[i],pal[j]));if(near>worst){worst=near;pal[k]=px[i];}}}}
  for(int it=0;it<8;it++){
   int sums[4][3]={0},n[4]={0};for(int i=0;i<64;i++){int k=0;for(int j=1;j<4;j++)if(visual_dist(px[i],pal[j])<visual_dist(px[i],pal[k]))k=j;n[k]++;sums[k][0]+=r(px[i]);sums[k][1]+=g(px[i]);sums[k][2]+=b(px[i]);}
   bool changed=false;for(int k=0;k<4;k++)if(n[k]){U16 v=(((sums[k][0]+n[k]/2)/n[k])<<11)|(((sums[k][1]+n[k]/2)/n[k])<<5)|((sums[k][2]+n[k]/2)/n[k]);changed|=v!=pal[k];pal[k]=v;}if(!changed)break;
  }
  std::vector<U8>t;t.push_back(136);for(int k=0;k<4;k++)word(t,pal[k]);for(int i=0;i<16;i++)t.push_back(0);
  for(int y=0;y<8;y++)for(int x=0;x<8;x++){int i=y*8+x;U16 v=px[(7-y)*8+x];int k=0;for(int j=1;j<4;j++)if(visual_dist(v,pal[j])<visual_dist(v,pal[k]))k=j;t[9+i/4]|=k<<(2*(i%4));}
  int err=token_error(px,t);if(err<best.error){best.error=err;best.tok=t;}
 }return best;
}
struct PointOrder{bool operator()(const Point&a,const Point&b)const{return a.cost<b.cost||(a.cost==b.cost&&a.error<b.error);}};

int main(int argc,char**argv){if(argc!=6)return 2;redesign_flags=atoi(argv[5]);quad_enable=1;frame_budget=atoi(argv[4]);solid_limit=atoi(argv[2]);pal_limit=atoi(argv[3]);_setmode(_fileno(stdin),_O_BINARY);FILE*f=fopen(argv[1],"wb+");if(!f)return 3;U8 header[512]={0};fwrite(header,1,512,f);std::vector<U16> raw(921600);unsigned frames=0;unsigned long long bytes=512;
 while(true){size_t n=fread(&raw[0],2,921600,stdin);if(!n)break;if(n!=921600)return 4;std::vector<U8>o;U16 px[64];
 // Encode source-order blocks exactly as reference, then reverse block rows
 // and token-local rows. This preserves palette tie order and every color.
 std::vector<std::vector<U8> >tokens(14400);std::vector<std::vector<Point> >frontiers(14400);std::vector<int>selected(14400,0);std::priority_queue<Upgrade,std::vector<Upgrade>,LowerGain>upgrades;int total=43201;
 for(int by=0;by<90;by++)for(int bx=0;bx<160;bx++){
  int k=by*160+bx;for(int y=0;y<8;y++)for(int x=0;x<8;x++)px[y*8+x]=raw[(by*8+y)*1280+bx*8+x];
  int sr=0,sg=0,sb=0;for(int i=0;i<64;i++){sr+=r(px[i]);sg+=g(px[i]);sb+=b(px[i]);}
  Point sol;sol.cost=3;sol.kind=0;sol.tok.push_back(128);word(sol.tok,((sr+32)/64<<11)|((sg+32)/64<<5)|(sb+32)/64);sol.error=token_error(px,sol.tok);
  std::vector<Point>all;all.push_back(sol);
  if(sol.error){
   if(redesign_flags&1)all.push_back(make_edge(px));
   if(redesign_flags&2)all.push_back(make_pal4(px));
   if(quad_enable){if(!(redesign_flags&4)&&!(redesign_flags&8)){Point q=make_quad(px),gr=make_gradient(px);all.push_back(gr.error<q.error?gr:q);}else if(!(redesign_flags&4))all.push_back(make_quad(px));else if(!(redesign_flags&8))all.push_back(make_gradient(px));}
   Point pal;pal.cost=13;pal.kind=2;pal.tok=best_pal2(px,sol.tok);pal.error=token_error(px,pal.tok);all.push_back(pal);
   Point exact;exact.cost=129;exact.kind=3;exact.error=0;exact.tok.push_back(131);for(int i=0;i<64;i++)word(exact.tok,px[i]);all.push_back(exact);
  }
  // Lower convex rate/distortion envelope, ordered by ascending byte cost.
  std::sort(all.begin(),all.end(),PointOrder());
  std::vector<Point>hull;
  for(size_t j=0;j<all.size();j++){
   Point p=all[j];if(!hull.empty()&&p.error>=hull.back().error)continue;
   while(hull.size()>=2){Point a=hull[hull.size()-2],b=hull.back();if((long long)(a.error-b.error)*(p.cost-b.cost)<=(long long)(b.error-p.error)*(b.cost-a.cost))hull.pop_back();else break;}
   hull.push_back(p);
  }
  frontiers[k]=hull;
  if(hull.size()>1){Upgrade u;u.index=k;u.gain=hull[0].error-hull[1].error;u.cost=hull[1].cost-hull[0].cost;u.stage=1;upgrades.push(u);}
 }
 while(!upgrades.empty()){
  Upgrade u=upgrades.top();upgrades.pop();if(total+u.cost>frame_budget)continue;int k=u.index;selected[k]=u.stage;total+=u.cost;
  if(u.stage+1<(int)frontiers[k].size()){Point a=frontiers[k][u.stage],b=frontiers[k][u.stage+1];Upgrade n;n.index=k;n.cost=b.cost-a.cost;n.gain=a.error-b.error;n.stage=u.stage+1;upgrades.push(n);}
 }
 for(int k=0;k<14400;k++)tokens[k]=frontiers[k][selected[k]].tok;
 for(int by=89;by>=0;by--)for(int bx=0;bx<160;bx++){
  std::vector<U8>&t=tokens[by*160+bx];
  if(t[0]==132){for(int i=0;i<4;i++)std::swap(t[1+i],t[5+i]);}
  if(t[0]==129)std::reverse(t.begin()+5,t.end());
  else if(t[0]==131)for(int y=0;y<4;y++)for(int x=0;x<16;x++)std::swap(t[1+y*16+x],t[1+(7-y)*16+x]);
  o.insert(o.end(),t.begin(),t.end());
 }
 o.push_back(255);fwrite(&o[0],1,o.size(),f);bytes+=o.size();frames++;if(frames%150==0){fprintf(stderr,"ENCODED frames=%u bytes=%llu\n",frames,bytes);fflush(stderr);}}
 if(bytes>0xffffffffULL)return 5;memcpy(header,"FPGV",4);header[4]=1;header[5]=12;header[6]=0;header[7]=5;header[8]=208;header[9]=2;header[10]=15;put32(header+12,(unsigned)bytes);put32(header+16,frames);U8 z[512]={0};fwrite(z,1,(512-bytes%512)%512,f);fseek(f,0,SEEK_SET);fwrite(header,1,512,f);fclose(f);fprintf(stderr,"DONE frames=%u bytes=%llu\n",frames,bytes);return 0;}
