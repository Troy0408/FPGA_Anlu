"""Read-only FAT32/contiguous BMP audit; never writes the volume or media.

The default audits files in the root used by the current FPGA catalog.
--directory optionally inspects a legacy subdirectory. Physical SD LBAs include
the BPB hidden-sector offset; physical ordering is diagnostic, while playback
uses directory order (or N01..N06 order for the complete showcase picture set).
"""
import argparse,hashlib,json,re,struct
from pathlib import Path

def u16(b,n):return struct.unpack_from('<H',b,n)[0]
def u32(b,n):return struct.unpack_from('<I',b,n)[0]
class Fat32:
    def __init__(self,drive):
        self.f=open('\\\\.\\'+drive,'rb',buffering=0)
        b=self.read(0,512)
        self.bps=u16(b,11);self.spc=b[13];self.reserved=u16(b,14);self.nfat=b[16];self.fatsz=u32(b,36)
        self.root=u32(b,44);self.hidden=u32(b,28);self.total=u32(b,32)
        if b[510:]!=b'\x55\xaa' or self.bps!=512 or not self.spc or not self.fatsz or self.root<2:
            raise ValueError('Expected512-byte-sector FAT32 volume')
        self.data_start=self.reserved+self.nfat*self.fatsz
        self.fat=self.read(self.reserved*512,self.fatsz*512)
    def read(self,offset,n):
        # Raw Windows volume reads require sector alignment.
        self.f.seek(offset);data=self.f.read(n)
        if len(data)!=n:raise ValueError('Short raw volume read')
        return data
    def chain(self,start):
        chain=[];seen=set();n=start
        while n<0xffffff8:
            if n<2 or n in seen or n*4+4>len(self.fat):raise ValueError('Invalid/cyclic FAT chain')
            chain.append(n);seen.add(n);n=u32(self.fat,n*4)&0xfffffff
        return chain
    def sector(self,cluster):return self.data_start+(cluster-2)*self.spc
    def entries(self,cluster):
        result=[]
        for c in self.chain(cluster):
            b=self.read(self.sector(c)*512,self.spc*512)
            for i in range(0,len(b),32):
                e=b[i:i+32]
                if e[0]==0:return result
                if e[0]==0xe5 or e[11]==0x0f or e[11]&8:continue
                base=e[:8].decode('ascii',errors='replace').rstrip();ext=e[8:11].decode('ascii',errors='replace').rstrip()
                name=base+('.'+ext if ext else '')
                result.append({'name':name,'cluster':u16(e,26)+(u16(e,20)<<16),'bytes':u32(e,28),'directory':bool(e[11]&16)})
        return result
    def file(self,e):
        chain=self.chain(e['cluster']);left=e['bytes'];h=hashlib.sha256()
        for c in chain:
            b=self.read(self.sector(c)*512,self.spc*512);h.update(b[:left]);left=max(0,left-len(b))
        if left:raise ValueError('Short file allocation')
        return {'name':e['name'],'bytes':e['bytes'],'sha256':h.hexdigest(),
                'clusters':len(chain),'contiguous':all(b==a+1 for a,b in zip(chain,chain[1:])),
                'first_card_lba':self.hidden+self.sector(chain[0]),
                'last_card_lba':self.hidden+self.sector(chain[-1])+self.spc-1}

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--drive',default='D:')
    ap.add_argument('--directory',default='');ap.add_argument('--output',type=Path,required=True)
    a=ap.parse_args()
    if not re.fullmatch('[A-Za-z]:',a.drive):ap.error('Use one Windows volume letter')
    if a.directory and not re.fullmatch('[A-Z0-9_]{1,8}',a.directory):ap.error('Use an uppercase8.3 directory name')
    if a.output.exists():ap.error('Evidence output already exists')
    fs=Fat32(a.drive);entries=fs.entries(fs.root)
    if a.directory:
        folders=[e for e in entries if e['directory'] and e['name']==a.directory]
        if len(folders)!=1:raise ValueError('Directory not present: '+a.directory)
        entries=fs.entries(folders[0]['cluster'])
    files=[fs.file(e) for e in entries if not e['directory']]
    bmps=sorted([e for e in files if e['name'].endswith('.BMP')],key=lambda e:e['first_card_lba'])
    record={'read_only':True,'drive':a.drive,'directory':a.directory,'bytes_per_sector':512,
        'sectors_per_cluster':fs.spc,'hidden_sectors':fs.hidden,'total_volume_sectors':fs.total,'files':files,
        'bmp_directory_order':[e['name'] for e in files if e['name'].endswith('.BMP')],
        'wav_directory_order':[e['name'] for e in files if e['name'].endswith('.WAV')],
        'bmp_physical_order':[e['name'] for e in bmps],
        'all_bmp_contiguous':bool(bmps) and all(e['contiguous'] for e in bmps)}
    if bmps:record['scan_start_sector']=bmps[0]['first_card_lba'];record['scan_max_sector']=max(e['last_card_lba'] for e in bmps)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in record.items() if k!='files'},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
