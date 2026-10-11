import processing.serial.*;
import cc.arduino.*;
import processing.sound.*;

Arduino arduino;

SoundFile[] decks = new SoundFile[2];

// FFT FOR REAL-TIME WAVEFORM / SPECTRUM
FFT fft;
int bands = 64;
float[] spectrum = new float[bands];

// SONGS
// Los archivos deben estar en la carpeta data
String[] songs = {
  "KANYE WEST x TY DOLLA $IGN TYPE BEAT - ''DANCE''.wav",
  "[FREE] ASAP ROCKY TYPE BEAT - ＂WATCH OUT＂.wav",
  "[FREE] Detroit Sample Type Beat x Yn Jay Type Beat - ＂3AM＂.wav"
};

// Deck song indexes
int[] deckSong = {0, 1};
int activeDeck = 0;

// POTENTIOMETERS
int potVolume = 0;   // A0
int potSpeed  = 1;   // A1
int potFX     = 2;   // A2

// BUTTONS
int button1 = 4;     // Play / Stop
int button2 = 7;     // Next Song on other deck
int button3 = 8;     // CUE

// LEDS
int ledPlay = 9;
int ledFX = 10;

// STATES
boolean playing = false;

// BUTTON MEMORY
int lastButton1 = Arduino.HIGH;
int lastButton2 = Arduino.HIGH;
int lastButton3 = Arduino.HIGH;

// CUE FLASH STATE
boolean cueFlash = false;
int cueFlashStartTime = 0;
int cueFlashDuration = 500;

// Visual rotation
float angleA = 0;
float angleB = 0;

// Debug console
int lastDebugTime = 0;

// Current audio values
float currentVolume = 0.8;
float currentSpeed = 1.0;

// SMOOTHED POT VALUES
float smoothVolumeValue = 512;
float smoothSpeedValue = 512;
float smoothFXValue = 512;

float lastStableSpeedValue = 512;

float smoothAmount = 0.08;
int speedNoiseThreshold = 6;

// For waveform animation
float waveformPhaseA = 0;
float waveformPhaseB = 0;

void setup() {
  size(1200, 700);

  println("Available ports:");
  println(Arduino.list());

  String portName = "";

  for (int i = 0; i < Arduino.list().length; i++) {
    String port = Arduino.list()[i];
    println(i + ": " + port);

    if (port.indexOf("usbmodem") != -1 || port.indexOf("usbserial") != -1) {
      portName = port;
    }
  }

  if (portName.equals("")) {
    println("ERROR: No Arduino USB port found.");
    println("Check cable, StandardFirmata, and close Arduino Serial Monitor.");
  } else {
    println("Using Arduino port: " + portName);
    arduino = new Arduino(this, portName, 57600);
  }

  if (arduino != null) {
    arduino.pinMode(button1, Arduino.INPUT_PULLUP);
    arduino.pinMode(button2, Arduino.INPUT_PULLUP);
    arduino.pinMode(button3, Arduino.INPUT_PULLUP);

    arduino.pinMode(ledPlay, Arduino.OUTPUT);
    arduino.pinMode(ledFX, Arduino.OUTPUT);
  }

  // Load first two decks
  loadDeck(0, 0);
  loadDeck(1, 1);

  // FFT setup
  fft = new FFT(this, bands);
}

void draw() {
  background(7, 9, 13);

  if (arduino == null) {
    fill(255, 80, 80);
    textAlign(CENTER);
    textSize(26);
    text("Arduino not found. Check USB port and StandardFirmata.", width / 2, height / 2);
    return;
  }

  // READ RAW POTENTIOMETERS
  int rawVolumeValue = arduino.analogRead(potVolume);
  int rawSpeedValue = arduino.analogRead(potSpeed);
  int rawFXValue = arduino.analogRead(potFX);

  // READ BUTTONS
  int button1State = arduino.digitalRead(button1);
  int button2State = arduino.digitalRead(button2);
  int button3State = arduino.digitalRead(button3);

  // SMOOTH POTENTIOMETERS
  smoothVolumeValue = lerp(smoothVolumeValue, rawVolumeValue, smoothAmount);
  smoothFXValue = lerp(smoothFXValue, rawFXValue, smoothAmount);

  // Special smoothing for speed pot
  if (abs(rawSpeedValue - lastStableSpeedValue) > speedNoiseThreshold) {
    lastStableSpeedValue = rawSpeedValue;
  }

  smoothSpeedValue = lerp(smoothSpeedValue, lastStableSpeedValue, smoothAmount);

  // DEBUG
  if (millis() - lastDebugTime > 500) {
    println(
      "RAW A0: " + rawVolumeValue +
      " | RAW A1: " + rawSpeedValue +
      " | RAW A2: " + rawFXValue +
      " || SMOOTH A1: " + int(smoothSpeedValue) +
      " | B4: " + button1State +
      " | B7: " + button2State +
      " | B8: " + button3State +
      " | ACTIVE DECK: " + (activeDeck == 0 ? "A" : "B")
    );
    lastDebugTime = millis();
  }

  // MAP VALUES
  float volume = map(smoothVolumeValue, 0, 1023, 0.0, 1.0);
  float speed = map(smoothSpeedValue, 0, 1023, 0.5, 1.8);
  float fadeAmount = map(smoothFXValue, 0, 1023, 0.0, 1.0);

  currentVolume = volume;
  currentSpeed = speed;

  // DJ FADE / PUMP FX
  // A2 bajo  -> sonido normal
  // A2 medio -> fade suave
  // A2 alto  -> fade fuerte tipo build-up / pump
  float t = millis() / 1000.0;

  float fadeRate = map(fadeAmount, 0.0, 1.0, 0.25, 3.2);
  float fadeWave = (sin(TWO_PI * fadeRate * t - HALF_PI) + 1.0) / 2.0;
  float fadeDepth = map(fadeAmount, 0.0, 1.0, 0.0, 0.92);

  float fadeVolumeMod = 1.0 - fadeDepth * (1.0 - fadeWave);

  float finalVolume = volume * fadeVolumeMod;
  finalVolume = constrain(finalVolume, 0.0, 1.0);

  float finalSpeed = speed;
  finalSpeed = constrain(finalSpeed, 0.4, 2.0);

  // BUTTON 1: PLAY / STOP ACTIVE DECK
  if (button1State == Arduino.LOW && lastButton1 == Arduino.HIGH) {
    if (playing) {
      stopActiveDeck();
    } else {
      startActiveDeck();
    }

    delay(200);
  }

  // BUTTON 2: NEXT SONG ON OTHER DECK
  if (button2State == Arduino.LOW && lastButton2 == Arduino.HIGH) {
    nextSongOtherDeck();
    delay(200);
  }

  // BUTTON 3: CUE / RESTART ACTIVE DECK
  if (button3State == Arduino.LOW && lastButton3 == Arduino.HIGH) {
    cueActiveDeck();

    cueFlash = true;
    cueFlashStartTime = millis();

    delay(200);
  }

  lastButton1 = button1State;
  lastButton2 = button2State;
  lastButton3 = button3State;

  // AUDIO CONTROL FOR ACTIVE DECK
  if (decks[activeDeck] != null && playing) {
    decks[activeDeck].amp(finalVolume);
    decks[activeDeck].rate(finalSpeed);
  }

  // Make sure inactive deck is silent
  int inactiveDeck = 1 - activeDeck;
  if (decks[inactiveDeck] != null) {
    decks[inactiveDeck].amp(0);
  }

  // FFT ANALYSIS FOR REAL-TIME WAVEFORM
  if (playing && fft != null) {
    fft.analyze(spectrum);
  } else {
    for (int i = 0; i < spectrum.length; i++) {
      spectrum[i] *= 0.90;
    }
  }

  // CUE LED TIMER
  if (cueFlash && millis() - cueFlashStartTime > cueFlashDuration) {
    cueFlash = false;
  }

  // LED FEEDBACK
  if (playing) {
    arduino.digitalWrite(ledPlay, Arduino.HIGH);
  } else {
    arduino.digitalWrite(ledPlay, Arduino.LOW);
  }

  if (cueFlash) {
    arduino.digitalWrite(ledFX, Arduino.HIGH);
  } else {
    arduino.digitalWrite(ledFX, Arduino.LOW);
  }

  // INTERFACE
  drawCDJInterface(volume, speed, fadeAmount, finalVolume, finalSpeed, playing, cueFlash);

  // Update jog wheels and waveform
  if (playing) {
    if (activeDeck == 0) {
      angleA += finalSpeed * 0.045;
      waveformPhaseA += finalSpeed * 1.7;
    } else {
      angleB -= finalSpeed * 0.045;
      waveformPhaseB += finalSpeed * 1.7;
    }
  }
}

void loadDeck(int deck, int songIndex) {
  if (songIndex >= songs.length) {
    songIndex = 0;
  }

  println("Loading Deck " + (deck == 0 ? "A" : "B") + ": " + songs[songIndex]);

  if (decks[deck] != null) {
    decks[deck].stop();
  }

  decks[deck] = new SoundFile(this, songs[songIndex]);
  deckSong[deck] = songIndex;

  if (decks[deck] == null) {
    println("ERROR: Could not load song: " + songs[songIndex]);
    return;
  }

  decks[deck].amp(0);
  decks[deck].rate(currentSpeed);

  if (deck == 0) {
    waveformPhaseA = 0;
    angleA = 0;
  } else {
    waveformPhaseB = 0;
    angleB = 0;
  }
}

void startActiveDeck() {
  if (decks[activeDeck] == null) {
    return;
  }

  println("START DECK " + (activeDeck == 0 ? "A" : "B") + ": " + songs[deckSong[activeDeck]]);

  // Stop both decks to avoid overlapping audio
  stopBothDecks();

  decks[activeDeck].amp(currentVolume);
  decks[activeDeck].rate(currentSpeed);
  decks[activeDeck].loop();

  if (fft != null) {
    fft.input(decks[activeDeck]);
  }

  playing = true;
}

void stopActiveDeck() {
  if (decks[activeDeck] == null) {
    return;
  }

  println("STOP DECK " + (activeDeck == 0 ? "A" : "B"));

  decks[activeDeck].stop();
  playing = false;
}

void stopBothDecks() {
  for (int i = 0; i < 2; i++) {
    if (decks[i] != null) {
      decks[i].stop();
      decks[i].amp(0);
    }
  }
}

void nextSongOtherDeck() {
  boolean wasPlaying = playing;

  println("NEXT SONG ON OTHER DECK");

  stopBothDecks();

  int oldActive = activeDeck;
  int newActive = 1 - activeDeck;

  int nextSong = deckSong[oldActive] + 1;
  if (nextSong >= songs.length) {
    nextSong = 0;
  }

  activeDeck = newActive;
  loadDeck(activeDeck, nextSong);

  playing = false;

  if (wasPlaying) {
    startActiveDeck();
  }
}

void cueActiveDeck() {
  if (decks[activeDeck] == null) {
    return;
  }

  println("CUE DECK " + (activeDeck == 0 ? "A" : "B"));

  boolean wasPlaying = playing;

  decks[activeDeck].stop();

  if (activeDeck == 0) {
    waveformPhaseA = 0;
    angleA = 0;
  } else {
    waveformPhaseB = 0;
    angleB = 0;
  }

  if (wasPlaying) {
    decks[activeDeck].amp(currentVolume);
    decks[activeDeck].rate(currentSpeed);
    decks[activeDeck].loop();

    if (fft != null) {
      fft.input(decks[activeDeck]);
    }

    playing = true;
  } else {
    playing = false;
  }
}

void drawCDJInterface(float volume, float speed, float fadeAmount, float finalVolume, float finalSpeed, boolean playing, boolean cueFlash) {
  background(7, 9, 13);

  // Main background
  noStroke();
  fill(15, 18, 28);
  rect(35, 30, 1130, 640, 35);

  // Title
  fill(235);
  textAlign(CENTER);
  textSize(28);
  text("ADVANCED MINI DJ CONTROLLER", width / 2, 65);

  fill(100, 200, 255);
  textSize(13);
  text("DUAL CDJ MODE | ARDUINO + PROCESSING | REAL-TIME AUDIO + VISUAL FEEDBACK", width / 2, 90);

  // Decks
  drawDeck(70, 120, 385, 520, "DECK A", 0, angleA, playing && activeDeck == 0, cueFlash && activeDeck == 0);
  drawDeck(745, 120, 385, 520, "DECK B", 1, angleB, playing && activeDeck == 1, cueFlash && activeDeck == 1);

  // Mixer
  drawMixer(475, 120, 250, 520, volume, speed, fadeAmount, finalVolume, finalSpeed, cueFlash);
}

void drawDeck(float x, float y, float w, float h, String title, int deck, float angle, boolean deckPlaying, boolean cueActive) {
  boolean isActive = activeDeck == deck;

  // Body
  noStroke();
  if (isActive) {
    fill(28, 34, 48);
  } else {
    fill(23, 25, 34);
  }
  rect(x, y, w, h, 26);

  // Active outline
  if (isActive) {
    noFill();
    stroke(0, 210, 255);
    strokeWeight(2);
    rect(x + 3, y + 3, w - 6, h - 6, 24);
    noStroke();
  }

  // Screen outer
  fill(8, 12, 18);
  rect(x + 22, y + 20, w - 44, 115, 14);

  // Screen inner
  fill(0, 25, 38);
  rect(x + 35, y + 35, w - 70, 80, 10);

  fill(0, 220, 255);
  textAlign(LEFT);
  textSize(14);
  text(title, x + 50, y + 58);

  fill(230);
  textSize(11);
  text("TRACK " + (deckSong[deck] + 1), x + 50, y + 77);

  fill(160, 220, 255);
  textSize(10);
  String shortName = songs[deckSong[deck]];
  if (shortName.length() > 34) {
    shortName = shortName.substring(0, 34) + "...";
  }
  text(shortName, x + 50, y + 95);

  if (cueActive) {
    fill(255, 190, 40);
    text("CUE", x + w - 75, y + 58);
  } else if (deckPlaying) {
    fill(0, 255, 120);
    text("PLAYING", x + w - 105, y + 58);
  } else if (isActive) {
    fill(255, 220, 0);
    text("READY", x + w - 90, y + 58);
  } else {
    fill(150);
    text("STANDBY", x + w - 105, y + 58);
  }

  // Real-time waveform / spectrum display
  drawWaveform(x + 35, y + 145, w - 70, 70, deck, deckPlaying, isActive);

  // Jog wheel
  float cx = x + w / 2;
  float cy = y + 320;

  fill(46, 50, 62);
  ellipse(cx, cy, 245, 245);

  fill(15, 18, 25);
  ellipse(cx, cy, 215, 215);

  fill(38, 42, 54);
  ellipse(cx, cy, 165, 165);

  fill(10, 12, 18);
  ellipse(cx, cy, 100, 100);

  // Jog grooves
  noFill();
  stroke(70, 75, 90);
  strokeWeight(1);
  ellipse(cx, cy, 195, 195);
  ellipse(cx, cy, 135, 135);
  ellipse(cx, cy, 75, 75);

  // Jog indicator
  pushMatrix();
  translate(cx, cy);
  rotate(angle);
  stroke(0, 210, 255);
  strokeWeight(5);
  line(0, 0, 0, -105);
  stroke(255);
  strokeWeight(2);
  line(0, -45, 0, -78);
  popMatrix();

  noStroke();

  // Center status
  if (cueActive) {
    fill(255, 190, 40);
  } else if (deckPlaying) {
    fill(0, 255, 120);
  } else if (isActive) {
    fill(255, 220, 0);
  } else {
    fill(90);
  }
  ellipse(cx, cy, 18, 18);

  // Performance pads
  for (int i = 0; i < 4; i++) {
    if (i == 0 && isActive) {
      fill(255, 120, 0);
    } else {
      fill(38, 42, 55);
    }
    rect(x + 45 + i * 75, y + 455, 58, 30, 7);
  }

  // Buttons
  drawCDJButton(x + 45, y + 500, 70, 38, "CUE", cueActive);
  drawCDJButton(x + 132, y + 500, 95, 38, deckPlaying ? "PLAY" : "STOP", deckPlaying);
  drawCDJButton(x + 248, y + 500, 85, 38, isActive ? "ACTIVE" : "LOAD", isActive);
}

void drawWaveform(float x, float y, float w, float h, int deck, boolean deckPlaying, boolean isActive) {
  // Waveform background
  noStroke();
  fill(5, 8, 12);
  rect(x, y, w, h, 10);

  // Center line
  stroke(50, 55, 60);
  strokeWeight(1);
  line(x + 5, y + h / 2, x + w - 5, y + h / 2);

  int localBars = bands;
  float barW = w / localBars;

  for (int i = 0; i < localBars; i++) {
    float amp;

    if (deckPlaying && isActive) {
      // Real FFT audio response
      amp = spectrum[i] * 900.0;
    } else {
      // Standby visual shape
      amp = 0.08 + 0.12 * abs(sin(i * 0.3 + deckSong[deck]));
    }

    amp = constrain(amp, 0, 1);

    float barH = map(amp, 0, 1, 5, h - 10);
    float bx = x + i * barW;
    float by = y + h / 2 - barH / 2;

    // ORANGE WAVEFORM
    if (isActive) {
      if (i % 6 == 0) {
        fill(255, 190, 0);
      } else if (i % 3 == 0) {
        fill(255, 120, 0);
      } else {
        fill(255, 80, 20);
      }
    } else {
      fill(75, 90, 105);
    }

    rect(bx + 1, by, max(1, barW - 2), barH, 2);
  }

  // Beat markers
  for (int i = 0; i < 8; i++) {
    float mx = x + i * (w / 8.0);
    stroke(255, 255, 255, 45);
    line(mx, y + 5, mx, y + h - 5);
  }

  // Playhead
  if (deckPlaying) {
    float phase;

    if (deck == 0) {
      phase = waveformPhaseA;
    } else {
      phase = waveformPhaseB;
    }

    float px = x + (phase % w);

    stroke(255, 190, 40);
    strokeWeight(2.5);
    line(px, y, px, y + h);

    noStroke();
    fill(255, 190, 40);
    triangle(px - 6, y - 5, px + 6, y - 5, px, y + 5);
  }

  // Mini overview line
  noStroke();
  fill(255, 255, 255, 35);
  rect(x + 10, y + h - 10, w - 20, 3, 2);
}

void drawMixer(float x, float y, float w, float h, float volume, float speed, float fadeAmount, float finalVolume, float finalSpeed, boolean cueFlash) {
  // Mixer body
  noStroke();
  fill(28, 30, 40);
  rect(x, y, w, h, 24);

  fill(230);
  textAlign(CENTER);
  textSize(18);
  text("DJ MIXER", x + w / 2, y + 35);

  fill(110, 200, 255);
  textSize(11);
  text("ACTIVE DECK: " + (activeDeck == 0 ? "A" : "B"), x + w / 2, y + 55);

  // Small screen
  fill(6, 10, 15);
  rect(x + 25, y + 70, w - 50, 55, 10);

  fill(0, 220, 255);
  textSize(12);
  text("DJ FADE FX", x + w / 2, y + 93);

  fill(230);
  textSize(10);
  text("A2 controls fade amount", x + w / 2, y + 110);

  // Knobs
  drawRealKnob(x + 65, y + 165, volume, "VOL");
  drawRealKnob(x + 185, y + 165, map(speed, 0.5, 1.8, 0, 1), "PITCH");

  drawRealKnob(x + 125, y + 235, fadeAmount, "FADE");

  // Status text
  if (cueFlash) {
    fill(255, 190, 40);
    textSize(18);
    text("CUE!", x + w / 2, y + 300);
  } else {
    fill(0, 220, 255);
    textSize(15);
    text("FADE READY", x + w / 2, y + 300);
  }

  // Sliders
  drawVerticalSlider(x + 55, y + 350, 105, volume, "CH VOL");
  drawVerticalSlider(x + 125, y + 350, 105, map(speed, 0.5, 1.8, 0, 1), "SPEED");
  drawVerticalSlider(x + 195, y + 350, 105, fadeAmount, "FX");

  // VU meters
  drawVUMeter(x + 35, y + 485, 80, finalVolume);
  drawVUMeter(x + 135, y + 485, 80, finalVolume * (0.4 + fadeAmount * 0.6));

  // Info text
  fill(255);
  textSize(12);
  text("Volume: " + int(volume * 100) + "%", x + w / 2, y + 515);
  text("Speed: " + nf(speed, 1, 2) + "x", x + w / 2, y + 535);
  text("Fade: " + int(fadeAmount * 100) + "%", x + w / 2, y + 555);
}

void drawRealKnob(float x, float y, float value, String label) {
  value = constrain(value, 0, 1);

  fill(12, 14, 20);
  ellipse(x, y, 72, 72);

  fill(45, 48, 60);
  ellipse(x, y, 58, 58);

  float a = map(value, 0, 1, -PI * 0.75, PI * 0.75);

  pushMatrix();
  translate(x, y);
  rotate(a);
  stroke(0, 210, 255);
  strokeWeight(4);
  line(0, 0, 0, -24);
  popMatrix();

  noStroke();
  fill(230);
  textAlign(CENTER);
  textSize(11);
  text(label, x, y + 52);
}

void drawVerticalSlider(float x, float y, float h, float value, String label) {
  value = constrain(value, 0, 1);

  fill(12, 14, 20);
  rect(x - 7, y, 14, h, 7);

  float knobY = y + h - value * h;

  fill(0, 210, 255);
  rect(x - 11, knobY - 8, 22, 16, 5);

  fill(230);
  textAlign(CENTER);
  textSize(10);
  text(label, x, y + h + 22);
}

void drawVUMeter(float x, float y, float w, float value) {
  value = constrain(value, 0, 1);

  fill(12, 14, 20);
  rect(x, y, w, 16, 8);

  int meterBars = 10;

  for (int i = 0; i < meterBars; i++) {
    float bx = x + 5 + i * 7.5;

    if (i < value * meterBars) {
      if (i < 6) {
        fill(0, 255, 120);
      } else if (i < 8) {
        fill(255, 220, 0);
      } else {
        fill(255, 70, 80);
      }
    } else {
      fill(40);
    }

    rect(bx, y + 4, 5, 8, 2);
  }
}

void drawCDJButton(float x, float y, float w, float h, String label, boolean active) {
  if (active) {
    fill(0, 210, 120);
  } else {
    fill(50, 55, 70);
  }

  rect(x, y, w, h, 8);

  fill(255);
  textAlign(CENTER);
  textSize(12);
  text(label, x + w / 2, y + h / 2 + 4);
}
