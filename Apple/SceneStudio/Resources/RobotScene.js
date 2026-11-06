const orange = new THREE.MeshStandardMaterial({color:0xf39935,metalness:0.25,roughness:0.42});
const silver = new THREE.MeshStandardMaterial({color:0xc7d6df,metalness:0.65,roughness:0.3});
const dark = new THREE.MeshStandardMaterial({color:0x25374a,metalness:0.5,roughness:0.45});
const blue = new THREE.MeshStandardMaterial({color:0x25b8ff,metalness:0.2,roughness:0.22});
function part(name,g,m,x,y,z){const p=new THREE.Mesh(g,m);p.name=name;p.position.set(x,y,z);scene.add(p);return p;}
part('torso',new THREE.BoxGeometry(0.6,0.8,0.35),orange,0,1.15,0);
part('neck',new THREE.CylinderGeometry(0.08,0.08,0.18,12),silver,0,1.64,0);
part('head',new THREE.SphereGeometry(0.28,20,16),silver,0,1.95,0);
for(let side=-1;side<=1;side+=2){
 const tag=side<0?'left':'right';
 part(tag+'_eye',new THREE.SphereGeometry(0.055,12,10),blue,side*0.1,1.98,0.25);
 const shoulder=part(tag+'_shoulder',new THREE.CylinderGeometry(0.07,0.07,0.2,12),dark,side*0.4,1.5,0);
 shoulder.rotation.z=Math.PI/2;
 part(tag+'_elbow',new THREE.SphereGeometry(0.085,12,10),silver,side*0.5,1.5,0);
 part(tag+'_arm',new THREE.CylinderGeometry(0.065,0.065,0.6,12),orange,side*0.5,1.2,0);
 part(tag+'_hand',new THREE.SphereGeometry(0.09,12,10),dark,side*0.5,0.9,0);
 part(tag+'_hip',new THREE.SphereGeometry(0.11,12,10),dark,side*0.16,0.75,0);
 part(tag+'_leg',new THREE.CylinderGeometry(0.075,0.075,0.6,12),silver,side*0.16,0.4,0);
 part(tag+'_foot',new THREE.BoxGeometry(0.2,0.16,0.35),dark,side*0.16,0.08,0.05);
}
