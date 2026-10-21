export const remoteKeys = [
  'MediaPlayPause', 'MediaPlay', 'MediaPause', 'MediaStop', 'MediaFastForward', 'MediaRewind',
  'MediaTrackPrevious', 'MediaTrackNext', 'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue'
];
export function registerRemote() {
  if (typeof tizen !== 'undefined' && tizen.tvinputdevice) {
    try {
      tizen.tvinputdevice.registerKeyBatch(remoteKeys, function () {}, function (error) { console.warn('Remote keys:', error.name); });
    } catch (error) { console.warn('Remote keys:', error.name); }
  }
}
export function bindKeys(actions) {
  registerRemote();
  document.addEventListener('keydown', event => {
    const code = event.keyCode;
    const input = /^(INPUT|TEXTAREA)$/.test(event.target.tagName) && !event.target.readOnly;
    let action = '';
    if (code === 10009 || event.key === 'Escape' || (!input && event.key === 'Backspace')) action = 'back';
    else if (code >= 37 && code <= 40 && (!input || code === 38 || code === 40)) action = ['left', 'up', 'right', 'down'][code - 37];
    else if (code === 13 && !input) action = 'enter';
    else if (code === 10252 || (!input && (event.key === ' ' || code === 32))) action = 'toggle';
    else if (code === 415) action = 'play';
    else if (code === 19) action = 'pause';
    else if (code === 413) action = 'stop';
    else if (code === 417) action = 'forward';
    else if (code === 412) action = 'rewind';
    else if (code === 10232) action = 'previous';
    else if (code === 10233) action = 'next';
    else if (code === 405 || (!input && /^[yY]$/.test(event.key))) action = 'lyrics';
    else if (code === 406 || (!input && /^[nN]$/.test(event.key))) action = 'now';
    if (action && actions[action]) {
      event.preventDefault();
      if (!event.repeat || ['left', 'right', 'up', 'down', 'forward', 'rewind'].indexOf(action) >= 0) actions[action]();
    }
  });
}
