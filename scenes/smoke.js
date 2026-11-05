const cube = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.2, 0.2), new THREE.MeshStandardMaterial({color: 0xaa2222, roughness: 0.7}));
cube.name = 'native-compiler-smoke';
cube.position.y = 0.1;
scene.add(cube);
