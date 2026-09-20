import {createHash} from 'node:crypto';
export const sha=b=>createHash('sha256').update(b).digest('hex');
export const checkpoints=[2,60,65,110,120];
export const buttonBits=[0x8000,0x4000,0x2000,0x1000,0x0800,0x0400,0x0200,0x0100,0x0080,0x0040,0x0020,0x0010];
export const movieChars='BYsSUDLRAXlr';
export const buttons=Array.from({length:120},(_,n)=>n<60?0:n<108?buttonBits[Math.floor((n-60)/4)]:n<115?0x8980:0);
export const movie='# zmov 1\n# start: power-on\n'+buttons.map(b=>[...movieChars].filter((_,i)=>b&buttonBits[i]).join('')).join('\n')+'\n';
export function ppmPixels(b) {
 const m=/^P6\s+(\d+)\s+(\d+)\s+255\n/.exec(b.toString('ascii',0,64));
 if(!m||+m[1]!==256||+m[2]!==224||b.length-m[0].length!==256*224*3)throw Error('Unexpected PPM');
 return b.subarray(m[0].length);
}
export function wavPcm(b) {
 if(b.toString('ascii',0,4)!=='RIFF'||b.toString('ascii',8,12)!=='WAVE')throw Error('Not WAV');
 let formatOK=false;
 for(let p=12;p+8<=b.length;) {
  const type=b.toString('ascii',p,p+4),n=b.readUInt32LE(p+4),start=p+8;
  if(type==='fmt ')formatOK=b.readUInt16LE(start)===1&&b.readUInt16LE(start+2)===2&&b.readUInt32LE(start+4)===32000&&b.readUInt16LE(start+14)===16;
  if(type==='data'){if(!formatOK||start+n>b.length)throw Error('Bad PCM');return b.subarray(start,start+n);}
  p=start+n+(n%2);
 }
 throw Error('No PCM');
}
