const showLogButton = document.getElementById("show-log");
const logDiv = document.getElementById("log");
logDiv.hidden = true;
showLogButton.addEventListener("click", () => {
  logDiv.hidden = !logDiv.hidden;
  logDiv.scroll({ top: logDiv.scrollHeight });
});
const log = (message) => {
  let shouldScroll =
    logDiv.scrollTop === logDiv.scrollHeight - logDiv.offsetHeight;
  logDiv.innerHTML += `<p>${message}</p>`;
  if (shouldScroll) logDiv.scroll({ top: logDiv.scrollHeight });
};

const readToEmscriptenFileSystem = (filename, filter = "") => {
  return new Promise((resolve, reject) => {
    let input = document.createElement("input");
    input.type = "file";
    input.accept = filter;
    input.addEventListener("input", () => {
      if (input.files?.length > 0) {
        let reader = new FileReader();
        reader.addEventListener("load", () => {
          let bytes = new Uint8Array(reader.result);
          let stream = FS.open(filename, "w+");
          FS.write(stream, bytes, 0, bytes.length, 0);
          FS.close(stream);
          resolve(bytes);
        });
        reader.readAsArrayBuffer(input.files[0]);
      }
    });
    input.click();
  });
};

const reportFps = (fps) => {
  let element = document.getElementById("fps");
  element.innerHTML = `FPS: ${fps}`;
};

document
  .getElementById("open-bios")
  .addEventListener("click", () => readToEmscriptenFileSystem("bios.bin"));

document
  .getElementById("open-rom")
  .addEventListener("click", () =>
    readToEmscriptenFileSystem("rom.gba", ".gba").then(() =>
      Module.ccall("initFromEmscripten", null, [], [])
    )
  );

var Module = {
  canvas: (() => document.getElementById("canvas"))(),
};

const pressKey = (keycode, down = true) => {
  let event = new Event(down ? "keydown" : "keyup", {
    bubbles: true,
    cancelable: "true",
  });
  event.keyCode = keycode;
  event.which = keycode;
  document.dispatchEvent(event);
};

const pressAllKeys = (keycodes, down) => {
  for (let keycode of keycodes) {
    pressKey(keycode, down);
  }
};

var currentDpadTouchId = null; // identifier of current Touch
var currentDpadElement = null; // element that is being touched

const getTouch = (touchList, touchId) => {
  for (let touch of touchList) {
    if (touch.identifier == touchId) {
      return touch;
    }
  }
};

const getKeycodes = (element) =>
  element?.getAttribute("keycodes")?.split(" ") ?? [];

const dpadTouchStart = (event) => {
  let element = event.target;
  if (currentDpadTouchId == null) {
    currentDpadTouchId = event.targetTouches[0].identifier; // start tracking first touch on dpad
    if (element.hasAttribute("keycodes")) {
      currentDpadElement = element;
      pressAllKeys(getKeycodes(element), true);
    }
  }
};

const dpadTouchMove = (event) => {
  if (currentDpadTouchId == null) return; // no idea what this event is
  let touch = getTouch(event.targetTouches, currentDpadTouchId);
  if (touch != null) {
    let element = document.elementFromPoint(touch.clientX, touch.clientY);
    if (element == currentDpadElement) return; // no need to process if element didn't change
    if (element == null) return; // somehow outside of screen
    let oldKeycodes = getKeycodes(currentDpadElement);
    if (element.hasAttribute("keycodes")) {
      let newKeycodes = getKeycodes(element);
      for (let oldKeycode of oldKeycodes) {
        if (newKeycodes.includes(oldKeycode)) continue; // no change necessary
        pressKey(oldKeycode, false);
      }
      for (let newKeycode of newKeycodes) {
        if (oldKeycodes.includes(newKeycode)) continue; // no change necessary
        pressKey(newKeycode, true);
      }
      currentDpadElement = element;
    } else {
      pressAllKeys(oldKeycodes, false);
      currentDpadElement = null;
    }
  }
};

const dpadTouchEnd = (event) => {
  let touch = getTouch(event.changedTouches, currentDpadTouchId);
  if (touch != null) {
    pressAllKeys(getKeycodes(currentDpadElement), false);
    currentDpadTouchId = null;
    currentDpadElement = null;
  }
};

document.getElementById("dpad").addEventListener("touchstart", dpadTouchStart);
document.getElementById("dpad").addEventListener("touchmove", dpadTouchMove);
document.getElementById("dpad").addEventListener("touchend", dpadTouchEnd);
document.getElementById("dpad").addEventListener("touchcancel", dpadTouchEnd);

document.querySelectorAll("[keycode]").forEach((element) =>
  element.addEventListener("touchstart", (event) => {
    pressKey(element.getAttribute("keycode"), true);
  })
);

document.querySelectorAll("[keycode]").forEach((element) =>
  element.addEventListener("touchend", (event) => {
    pressKey(element.getAttribute("keycode"), false);
  })
);
