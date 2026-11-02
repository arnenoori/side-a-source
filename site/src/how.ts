import './how.css';
import { mountAppMock } from './app-mock';
import { mountIsland } from './island';
import { mountLiveMock } from './live-mock';
import { mountKeepAwake } from './keep-awake';
import { mountRemote } from './remote';

export function mountHow(root: HTMLElement) {
  root.classList.add('ready');
  const desk = root.querySelector<HTMLElement>('.hero .desk');
  if (desk) mountAppMock(desk);
  const live = root.querySelector<HTMLElement>('[data-live-mock]');
  if (live) mountLiveMock(live);
  const islandSection = root.querySelector('#island');
  const islandDemo = islandSection?.querySelector<HTMLElement>('.island-demo');
  if (islandSection && islandDemo) mountIsland(islandDemo, islandSection);
  const awake = root.querySelector<HTMLElement>('[data-keep-awake]');
  if (awake) mountKeepAwake(awake);
  const remote = root.querySelector<HTMLElement>('#remote');
  if (remote) mountRemote(remote);

  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      entry.target.classList.toggle('playing', entry.isIntersecting);
      if (entry.isIntersecting) entry.target.classList.add('seen');
    }
  }, { threshold: 0.25 });
  root.querySelectorAll('[data-demo]').forEach(section => observer.observe(section));
}
