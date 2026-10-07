import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as THREE from 'three';
import { createPlayerFraming } from '../src/framing.mjs';

const model = JSON.parse(readFileSync(new URL('../../Sources/SideA/Resources/discman.json', import.meta.url)));
for (const [name, aspect] of [['phone', 346 / 420], ['short phone', 276 / 300], ['desktop', 800 / 540]]) {
  test(`${name}: every model vertex stays inside the frame throughout opening and rotation`, () => {
    const player = new THREE.Group();
    const hinge = new THREE.Group();
    hinge.position.set(0, .45, -2.05);
    player.add(hinge);
    const meshes = model.map(item => {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(item.vertices, 3));
      const mesh = new THREE.Mesh(geometry);
      if (item.lid) { mesh.position.set(0, -.45, 2.05); hinge.add(mesh); }
      else player.add(mesh);
      return mesh;
    });
    const camera = new THREE.OrthographicCamera(-3, 3, 2, -2, .1, 100);
    camera.position.set(.55, 8.8, 5.3);
    camera.lookAt(0, .22, 0);
    const fit = createPlayerFraming(camera, player);
    const point = new THREE.Vector3();
    const matrix = new THREE.Matrix4();
    for (const yaw of [-.65, -.12, .65]) {
      for (const lid of [0, -.28, -.56, -.84, -1.12]) {
        player.rotation.y = yaw;
        hinge.rotation.x = lid;
        fit(aspect);
        let maxX = 0, maxY = 0, maxZ = 0;
        for (const mesh of meshes) {
          matrix.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse).multiply(mesh.matrixWorld);
          const positions = mesh.geometry.attributes.position;
          for (let i = 0; i < positions.count; i++) {
            point.fromBufferAttribute(positions, i).applyMatrix4(matrix);
            maxX = Math.max(maxX, Math.abs(point.x));
            maxY = Math.max(maxY, Math.abs(point.y));
            maxZ = Math.max(maxZ, Math.abs(point.z));
          }
        }
        assert.ok(maxX <= .9 && maxY <= .9 && maxZ < 1, `Clipped at yaw ${yaw}, lid ${lid}: ${maxX}, ${maxY}, ${maxZ}`);
      }
    }
  });
}
