#include "PEImports.h"
#include <stdio.h>
#include <stdlib.h>
static void show(const char *dll,const char *function,int delayed,void *context) {
    (void)context; printf("%s|%s|%d\n",dll,function,delayed);
}
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    FILE *f=fopen(argv[1],"rb"); if (!f) return 2;
    if (fseek(f,0,SEEK_END)) { fclose(f); return 2; }
    long n=ftell(f);
    if (n<0 || n>128*1024*1024) { fclose(f); return 2; }
    rewind(f);
    unsigned char *p=malloc((size_t)n ? (size_t)n : 1);
    if (!p) { fclose(f); return 2; }
    if (fread(p,1,(size_t)n,f)!=(size_t)n) { free(p); fclose(f); return 2; }
    fclose(f);
    int result=bcd_pe_imports(p,(size_t)n,show,NULL); free(p);
    return result<0 ? 2 : 0;
}
