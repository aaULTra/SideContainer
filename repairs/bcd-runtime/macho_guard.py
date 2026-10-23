"""Strict Mach-O metadata and additive load-command changes for the pinned BCD IPA."""
import argparse
import hashlib
import json
import pathlib
import struct

OLD_LOG = b'[launch] wineserver ready after %.0f ms'
NEW_LOG = b'[launch] wineserver wait ended: %.0f ms'
assert len(OLD_LOG) == len(NEW_LOG)

class MachO:
    def __init__(self, data):
        self.data = data
        magic, self.cpu, subtype, kind, self.ncmds, self.command_size, flags, reserved = struct.unpack_from('<8I', data)
        assert magic == 0xfeedfacf and self.cpu in (0x100000c, 0x1000007), 'Expected a thin 64-bit Mach-O'
        self.commands = []
        self.sections = []
        self.uuid = None
        self.symtab = self.dysymtab = None
        self.base = None
        offset = 32
        for i in range(self.ncmds):
            cmd, size = struct.unpack_from('<II', data, offset)
            assert size >= 8 and offset + size <= 32 + self.command_size
            self.commands.append((cmd, offset, size))
            if cmd == 0x1b:
                self.uuid = data[offset+8:offset+24]
            elif cmd == 2:
                self.symtab = struct.unpack_from('<4I', data, offset+8)
            elif cmd == 11:
                self.dysymtab = struct.unpack_from('<18I', data, offset+8)
            elif cmd == 0x19:
                name, va, vs, fo, fs, maxprot, prot, count, segmentflags = struct.unpack_from('<16s4Q4I', data, offset+8)
                if name.rstrip(b'\0') == b'__TEXT': self.base = va
                for j in range(count):
                    row = struct.unpack_from('<16s16sQQIIIIIIII', data, offset+72+80*j)
                    self.sections.append({'name':row[0].rstrip(b'\0').decode(), 'segment':row[1].rstrip(b'\0').decode(),
                                          'address':row[2], 'size':row[3], 'offset':row[4], 'flags':row[8], 'reserved1':row[9]})
            offset += size
        assert offset == 32+self.command_size
        assert self.uuid and self.base is not None and self.symtab
        self.symbols = []
        symoff, count, strings, string_size = self.symtab
        for i in range(count):
            index, typ, section, description, value = struct.unpack_from('<IBBHQ', data, symoff+16*i)
            assert index < string_size
            end = data.find(b'\0', strings+index, strings+string_size)
            assert end >= 0
            name = data[strings+index:end].decode(errors='replace')
            self.symbols.append((name, typ, section, value))

    def address(self, name):
        values={v for n,t,s,v in self.symbols if n==name and not t&0xe0 and t&0xe==0xe}
        assert len(values)==1, f'Expected exactly one definition of {name}'
        return values.pop()

    def file_offset(self, address):
        sections=[s for s in self.sections if s['address']<=address<s['address']+s['size'] and s['offset']]
        assert len(sections)==1
        return sections[0]['offset']+address-sections[0]['address']

    def startup_metadata(self):
        start=self.address('_wine_process_start')
        code_section=next(i+1 for i,s in enumerate(self.sections) if s['name']=='__text' and s['segment']=='__TEXT')
        following={v for n,t,s,v in self.symbols if not t&0xe0 and t&0xe==0xe and s==code_section and v>start}
        end=min(following)
        assert 0<end-start<0x10000
        slots=[]
        for section in self.sections:
            if section['flags']&0xff not in (6,7): continue
            assert self.dysymtab
            for i in range(section['size']//8):
                ix=struct.unpack_from('<I',self.data,self.dysymtab[12]+4*(section['reserved1']+i))[0]
                if ix&0xc0000000:continue
                assert ix<len(self.symbols)
                if self.symbols[ix][0]=='_socketpair': slots.append(section['address']+i*8)
        assert len(slots)==1, f'Expected one socketpair import, found {slots}'
        ready=self.address('_wineserver_is_ready')
        running=self.address('_wineserver_is_running')
        client_running=self.address('_g_wine_running')
        return {'cpu':self.cpu,'uuid':self.uuid.hex(),'wine_start':start-self.base,'wine_end':end-self.base,
                'ready':ready-self.base,'running':running-self.base,'socketpair_slot':slots[0]-self.base,
                'client_running':client_running-self.base,
                'start_bytes':self.data[self.file_offset(start):self.file_offset(start)+16].hex(),
                'ready_bytes':self.data[self.file_offset(ready):self.file_offset(ready)+16].hex()}

    def inject(self, path, neutral_log=True):
        name=path.encode()+b'\0'
        size=(24+len(name)+7)&~7
        end=32+self.command_size
        first=min(s['offset'] for s in self.sections if s['offset'])
        assert end+size<=first and not any(self.data[end:end+size]), 'No unused header padding'
        command=struct.pack('<6I',0xc,size,24,0,0x10000,0x10000)+name
        command+=bytes(size-len(command))
        d=bytearray(self.data)
        d[end:end+size]=command
        struct.pack_into('<II',d,16,self.ncmds+1,self.command_size+size)
        allowed=set(range(16,24))|set(range(end,end+size))
        if neutral_log:
            assert d.count(OLD_LOG)==1, 'The optimistic readiness log must occur exactly once'
            at=d.index(OLD_LOG)
            d[at:at+len(OLD_LOG)]=NEW_LOG
            allowed.update(range(at,at+len(OLD_LOG)))
        assert len(d)==len(self.data)
        assert all(i in allowed for i,(a,b) in enumerate(zip(self.data,d)) if a!=b), 'Unexpected executable modification'
        # No existing executable instruction or section layout may change.
        text=next(s for s in self.sections if s['name']=='__text' and s['segment']=='__TEXT')
        begin=text['offset'];finish=begin+text['size']
        assert self.data[begin:finish]==d[begin:finish]
        return bytes(d)

def write_header(metadata, path):
    fields={'BCD_IMAGE_CPU':'cpu','BCD_WINE_START':'wine_start','BCD_WINE_END':'wine_end',
            'BCD_READY':'ready','BCD_RUNNING':'running','BCD_CLIENT_RUNNING':'client_running','BCD_SOCKETPAIR_SLOT':'socketpair_slot'}
    lines=['/* Generated from the exact original Mach-O; never hand-edited. */']
    for macro,key in fields.items():lines.append(f'#define {macro} 0x{metadata[key]:x}ULL')
    for name,key in [('BCD_IMAGE_UUID','uuid'),('BCD_START_BYTES','start_bytes'),('BCD_READY_BYTES','ready_bytes')]:
        values=', '.join(f'0x{x:02x}' for x in bytes.fromhex(metadata[key]))
        lines.append(f'static const unsigned char {name}[] = {{{values}}};')
    pathlib.Path(path).write_text('\n'.join(lines)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('binary');parser.add_argument('--header');parser.add_argument('--metadata');parser.add_argument('--inject')
    args=parser.parse_args()
    path=pathlib.Path(args.binary);m=MachO(path.read_bytes())
    metadata=m.startup_metadata()
    if args.header:write_header(metadata,args.header)
    if args.metadata:pathlib.Path(args.metadata).write_text(json.dumps(metadata,indent=2)+'\n')
    if args.inject:path.write_bytes(m.inject(args.inject))
    print(json.dumps(metadata,indent=2))
