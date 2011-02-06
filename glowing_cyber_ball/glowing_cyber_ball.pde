/*
 * Heavily modified version of work by:
 * Devon D. Jones < soulcatcher@evilsoft.org
 * http://www.evilsoft.org
 *
 * Which is in turn an evolution of:
 * Tod E. Kurt <tod@todbot.com
 * http://todbot.com/
 */

/*
 * This program can take a number of inputs on the serial port:
 * 1) #[HHHHHH] where H = Hex.  Example: #FF6666.  This will set the orb to the color that is declared.
 * 2) roam.  This will cause the orb to float between colors
 * 3) %[HHHHHH] where H = Hex.  Examples: %, %00FF00.  This will put the orb into alert mode, where
 *    it will flash between the color (or FF0000 if no color is passed in) and a very dim version of the color
 */

#include <SoftwareSerial.h>

/* ========================================================
 * Begin config
 * ========================================================
 */

// The hardware pins our three LED clusters are connected to
#define RED_PIN 9
#define GREEN_PIN 11
#define BLUE_PIN 3

// The hardware pins our bluesmirf is connected to
#define BT_TX_PIN 7
#define BT_RX_PIN 8

// For random colors, this is the lower & upper bound.
// The result is multiplied by 16, and then normalized to 0-255
// we start at -3 and go to 20 to bias the randomness towards 0 and 255
// because it results in generally better colors
#define MIN_RAND -3
#define MAX_RAND 40

// For color transition we use varied transition speed,
// this is the lower & upper bound.
#define STEP_MIN 2
#define STEP_MAX 8

// The delay used between loops
#define LOOP_DELAY 500

// Serial baud rate
#define SERIAL_BAUD 9600
#define BT_SERIAL_BAUD 9600

// interval used between swap requests
#define ALERT_INTERVAL 300

/* ========================================================
 * Globals
 * ======================================================== */

// Because C is lazy and stupid
#define TRUE 1
#define FALSE 0

// Array to hold the incoming serial string bytes
#define SLEN 7        // 7 characters, e.g. '#ff6666'
char _serial_input[SLEN];

// Struct representing a single led
struct led {
  int curr; // Current brightness
  int dest; // Next intended brightness
  int step; // If transitioning from one brightness to another, this is the amount to step by
};

// Struct representing the 3 leds
struct led_colors {
  led red;
  led green;
  led blue;
};
led_colors _colors;

// Roam state
int _roam = FALSE;

// Alert state
int _alert = FALSE;

// Used to determine when to swap colors
unsigned long _alert_millis = 0;

// A SoftwareSerial instance for our bluesmirf
SoftwareSerial BlueSerial(BT_RX_PIN, BT_TX_PIN);

/* ========================================================
 * Function definitions
 * ======================================================== */

int read_serial_string();
void decode_color(long colorVal);
void display_color(int red, int green, int blue);
void init_struct();
void prep_roam();
void prep_alert();
int do_roam();
void do_alert();
int roam_color(int curr, int dest, int step);
int get_random_color();

/* ========================================================
 * Now the real fun starts
 * ======================================================== */

// Arduino startup hook
void setup() {
  // Set our three output pins
  pinMode(RED_PIN,   OUTPUT);
  pinMode(GREEN_PIN, OUTPUT);
  pinMode(BLUE_PIN,  OUTPUT);

  // Set the serial ports for debugging output
  Serial.begin(SERIAL_BAUD);
  BlueSerial.begin(BT_SERIAL_BAUD);

  Serial.println("Serial port initialized");
  BlueSerial.println("BlueSmirf serial port initialized");

  // Start off in quiet mode
  _roam = FALSE;
  _alert = FALSE;

}

// Main Arduino loop
void loop () {
  // Read a line of input
  int spos = read_serial_string();

  /* =============================================
   * Step 1: Parse our input and decide what to do
   * =============================================
   */
  if(spos == SLEN && _serial_input[0] == '#') {
    // We've been given a command color
    _roam = FALSE;
    _alert = FALSE;

    // Parse the hex representation of our color into a long, then decode it
    long color_val = strtol(_serial_input + 1, NULL, 16);
    decode_color(color_val);

    // Display our decoded color
    display_color(_colors.red.curr, _colors.green.curr, _colors.blue.curr);

    // Clear our input by writing zeroes to the whole thing
    memset(_serial_input, 0, SLEN);      // indicates we've used this string
  }
  else if(spos != -1 && _serial_input[0] == '%') {
    // We've been given an "alert" command (starts with "%")
    _roam = FALSE;
    _alert = TRUE;
    init_struct();
    if(spos == SLEN) {
      // We've been given an alrt color
      long color_val = strtol(_serial_input + 1, NULL, 16);
      decode_color(color_val);
    }
    else {
      // We haven't been give a proper color. Just be red
      _colors.red.curr = 255;
    }
    prep_alert();
  }
  else if(spos != -1 && strncmp(_serial_input, "roam", 4) == 0 && !_roam) {
    // We've been given the "roam" command
    _alert = FALSE;
    _roam = TRUE;
    init_struct();
    prep_roam();
  }
  else if(spos != -1 && strncmp(_serial_input, "off", 3) == 0) {
    // We've been given the "off" command
    _alert = FALSE;
    _roam = FALSE;
    init_struct();
    display_color(0, 0, 0);
  }

  // If we're in roam mode
  if( _roam ) {
    int ret = do_roam();
    display_color(_colors.red.curr, _colors.green.curr, _colors.blue.curr);
    if(ret > 0) {
      prep_roam();
    }
  }

  // If we're in alert mode
  if(_alert == 1) {
    do_alert();
    display_color(_colors.red.curr, _colors.green.curr, _colors.blue.curr);
  }

  Serial.print("Current r:");
  Serial.print(_colors.red.curr);
  Serial.print(" g:");
  Serial.print(_colors.green.curr);
  Serial.print(" b:");
  Serial.println(_colors.blue.curr);
  BlueSerial.print("Current r:");
  BlueSerial.print(_colors.red.curr);
  BlueSerial.print(" g:");
  BlueSerial.print(_colors.green.curr);
  BlueSerial.print(" b:");
  BlueSerial.println(_colors.blue.curr);
  delay(LOOP_DELAY);  // wait a bit, for serial data
}

// Takes in a string in ?000000 - ?FFFFFF format (Ex: #FFAA33)
// and sets the curr color to the value
void decode_color(long color_val) {
  // Clever. Masks out the selected color
  _colors.red.curr = (color_val & 0xff0000) >> 16;
  _colors.green.curr = (color_val & 0x00ff00) >> 8;
  _colors.blue.curr = (color_val & 0x0000ff) >> 0;

  Serial.print("setting color to r:");
  Serial.print(_colors.red.curr);
  Serial.print(" g:");
  Serial.print(_colors.green.curr);
  Serial.print(" b:");
  Serial.println(_colors.blue.curr);
}

// "Render" our chosen color
void display_color(int red, int green, int blue) {
  analogWrite(RED_PIN, red);
  analogWrite(GREEN_PIN, green);
  analogWrite(BLUE_PIN, blue);
}

// Read a string from the serial and store it in an array
int read_serial_string () {
  int i = 0;
  if(!Serial.available()) {
    return -1;
  }
  while (Serial.available() && i < SLEN) {
    int c = Serial.read();
      _serial_input[i++] = c;
  }
  Serial.println(_serial_input);
  return i;
}

// Clears our struct
void init_struct() {
  _colors.red.curr = 0;
  _colors.red.dest = 0;
  _colors.red.step = 0;

  _colors.green.curr = 0;
  _colors.green.dest = 0;
  _colors.green.step = 0;

  _colors.blue.curr = 0;
  _colors.blue.dest = 0;
  _colors.blue.step = 0;
}

// Makes the light do the blinky blinky
void do_alert() {
  if (millis() - _alert_millis > ALERT_INTERVAL) {
    _alert_millis = millis();
    int tmp = 0;
    tmp = _colors.red.curr;
    _colors.red.curr = _colors.red.dest;
    _colors.red.dest = tmp;

    tmp = _colors.green.curr;
    _colors.green.curr = _colors.green.dest;
    _colors.green.dest = tmp;

    tmp = _colors.blue.curr;
    _colors.blue.curr = _colors.blue.dest;
    _colors.blue.dest = tmp;
  }
}

// Preps the dest to start the alert
void prep_alert() {
  _colors.red.dest = _colors.red.curr / 8;
  _colors.green.dest = _colors.green.curr / 8;
  _colors.blue.dest = _colors.blue.curr / 8;
}

// Randomizes colors for the roam mode
int do_roam() {
  _colors.red.curr = roam_color(_colors.red.curr, _colors.red.dest, _colors.red.step);
  _colors.green.curr = roam_color(_colors.green.curr, _colors.green.dest, _colors.green.step);
  _colors.blue.curr = roam_color(_colors.blue.curr, _colors.blue.dest, _colors.blue.step);
  if((_colors.red.curr == _colors.red.dest)
      && (_colors.green.curr == _colors.green.dest)
      && (_colors.blue.curr == _colors.blue.dest)) {
    return 1;
  }
  return 0;
}

// Roams a color based on its current state
int roam_color(int curr, int dest, int step) {
  int diff = curr - dest;
  if(diff < 0) {
    diff = diff * -1;
  }

  if(curr == dest) {
    return dest;
  }
  else if(curr < dest) {
    if(diff <= step) {
      return dest;
    }
    return curr + step;
  }
  else {
    if(diff <= step) {
      return dest;
    }
    return curr - step;
  }
}

// Preps to start the roam
void prep_roam() {
  randomSeed(millis());
  _colors.red.dest = get_random_color();
  _colors.red.step = random(STEP_MIN, STEP_MAX);
  _colors.green.dest = get_random_color();
  _colors.green.step = random(STEP_MIN, STEP_MAX);
  _colors.blue.dest = get_random_color();
  _colors.blue.step = random(STEP_MIN, STEP_MAX);
  Serial.print("Roaming to r:");
  Serial.print(_colors.red.dest);
  Serial.print(" g:");
  Serial.print(_colors.green.dest);
  Serial.print(" b:");
  Serial.println(_colors.blue.dest);
}

// Get a random hex color
int get_random_color() {
  int color = (random(MIN_RAND, MAX_RAND) * 16) -1;
  if (color < 0) color = 0;
  if (color > 255) color = 255;
  return color;
}

