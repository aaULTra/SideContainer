#include "PEImports.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct { const unsigned char *p; size_t size, sections; uint16_t count; int wide; uint64_t base; } PE;
static int range(size_t size,size_t at,size_t n) { return at<=size && n<=size-at; }
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0]|(uint16_t)p[1]<<8); }
static uint32_t u32(const unsigned char *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static size_t offset(PE *pe,uint64_t rva,size_t need) {
    for (unsigned i=0;i<pe->count;i++) {
        const unsigned char *s=pe->p+pe->sections+i*40;
        uint32_t va=u32(s+12), raw=u32(s+16), at=u32(s+20);
        if (rva>=va && rva-va<=raw && need<=raw-(rva-va) && range(pe->size,at,raw)) return at+(size_t)(rva-va);
    }
    return SIZE_MAX;
}
static const char *name(PE *pe,uint64_t rva) {
    size_t at=offset(pe,rva,1); if (at==SIZE_MAX) return NULL;
    for (size_t n=0;n<512;n++) {
        if (offset(pe,rva,n+1)==SIZE_MAX) return NULL;
        unsigned char c=pe->p[at+n];
        if (!c) return n ? (const char *)(pe->p+at) : NULL;
        if (c<32 || c>126) return NULL;
    }
    return NULL;
}
static int visit_table(PE *pe,uint32_t rva,uint32_t size,int delay,BCDImportVisitor cb,void *ctx) {
    if (!rva) return 0;
    size_t width=delay?32:20; if (size<width) return -1;
    unsigned count=0; int terminated=0;
    for (unsigned i=0;i<256 && (uint64_t)(i+1)*width<=size;i++) {
        size_t at=offset(pe,(uint64_t)rva+i*width,width); if (at==SIZE_MAX) return -1;
        const unsigned char *d=pe->p+at; unsigned nonzero=0;
        for (size_t j=0;j<width;j++) nonzero|=d[j];
        if (!nonzero) {terminated=1;break;}
        uint64_t dll=u32(d+(delay?4:12)), thunk=delay?u32(d+16):u32(d);
        if (!thunk) thunk=u32(d+(delay?12:16));
        int relative=!delay || (u32(d)&1);
        if (!relative) {if (dll<pe->base || thunk<pe->base)return -1;dll-=pe->base;thunk-=pe->base;}
        const char *library=name(pe,dll); if (!library || !thunk)return -1;
        int thunk_end=0;
        for (unsigned j=0;j<4096;j++) {
            size_t t=offset(pe,thunk+(uint64_t)j*(pe->wide?8:4),pe->wide?8:4);if(t==SIZE_MAX)return -1;
            uint64_t value=pe->wide?u64(pe->p+t):u32(pe->p+t);
            if(!value){thunk_end=1;break;}
            uint64_t ordinal_mask=pe->wide?UINT64_C(0x8000000000000000):UINT64_C(0x80000000);
            const char *function;char ordinal[24];
            if(value&ordinal_mask){snprintf(ordinal,sizeof(ordinal),"#%u",(unsigned)(value&0xffff));function=ordinal;}
            else {
                if(!relative){if(value<pe->base)return -1;value-=pe->base;}
                if(value>UINT32_MAX || offset(pe,value,2)==SIZE_MAX)return -1;
                function=name(pe,value+2);if(!function)return -1;
            }
            if(cb) cb(library,function,delay,ctx);
            count++;
        }
        if(!thunk_end)return -1;
    }
    return terminated?(int)count:-1;
}
int bcd_pe_imports(const unsigned char *p,size_t size,BCDImportVisitor visitor,void *context) {
    if(!p || !range(size,0,64) || p[0]!='M' || p[1]!='Z')return -1;
    size_t coff=u32(p+60);if(!range(size,coff,24) || memcmp(p+coff,"PE\0\0",4))return -1;
    uint16_t sections=u16(p+coff+6), optional=u16(p+coff+20);size_t opt=coff+24;
    if(!sections || sections>96 || optional<2 || !range(size,opt,optional))return -1;
    int wide=u16(p+opt)==0x20b;
    if(!wide && u16(p+opt)!=0x10b)return -1;
    size_t dir=wide?112:96;
    if(optional<dir || !range(size,opt+optional,(size_t)sections*40))return -1;
    uint32_t directories=u32(p+opt+(wide?108:92));
    PE pe={p,size,opt+optional,sections,wide,wide?u64(p+opt+24):u32(p+opt+28)};
    int total=0;
    for(unsigned pass=0;pass<2;pass++) {
        unsigned index=pass?13:1;if(index>=directories)continue;
        if((size_t)(index+1)*8>optional-dir)return -1;
        uint32_t rva=u32(p+opt+dir+index*8),bytes=u32(p+opt+dir+index*8+4);
        int found=visit_table(&pe,rva,bytes,pass,visitor,context);if(found<0)return -1;total+=found;
    }
    return total;
}
