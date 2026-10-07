import { Box3, Matrix4, Vector3 } from 'three';

/** Fit the current pose in camera space, including every part of the moving lid. */
export function createPlayerFraming(camera, player) {
  const bounds = new Box3();
  const point = new Vector3();
  const matrix = new Matrix4();
  const meshes = [];
  player.traverse(object => {
    if (!object.isMesh) return;
    object.geometry.computeBoundingBox();
    meshes.push(object);
  });
  return aspect => {
    if (!(aspect > 0) || !Number.isFinite(aspect)) return;
    player.updateMatrixWorld(true);
    camera.updateMatrixWorld(true);
    bounds.makeEmpty();
    for (const mesh of meshes) {
      const box = mesh.geometry.boundingBox;
      matrix.multiplyMatrices(camera.matrixWorldInverse, mesh.matrixWorld);
      for (const x of [box.min.x, box.max.x]) {
        for (const y of [box.min.y, box.max.y]) {
          for (const z of [box.min.z, box.max.z]) {
            bounds.expandByPoint(point.set(x, y, z).applyMatrix4(matrix));
          }
        }
      }
    }
    const halfHeight = Math.max(bounds.max.y - bounds.min.y, (bounds.max.x - bounds.min.x) / aspect) * 0.56;
    const centerX = (bounds.min.x + bounds.max.x) / 2;
    const centerY = (bounds.min.y + bounds.max.y) / 2;
    camera.left = centerX - halfHeight * aspect;
    camera.right = centerX + halfHeight * aspect;
    camera.bottom = centerY - halfHeight;
    camera.top = centerY + halfHeight;
    camera.updateProjectionMatrix();
  };
}
