import s373.flob.*;
import processing.serial.*;
import java.util.*;
import java.util.concurrent.*;
float displayScale;

PGraphics buffer, curFrame;
PImage img;

Board board;

Serial myPort;

GenerateThread generate;

// define some constants

int maxBlob = 0; // highest blob ID we've hit
int thresh = 130, movementThreshold = 300, blurRadius = 8, minBlobSize = 30, maxBlobSize = 50000; // for tracking purposes
int totalModules = 20;

Flob flob;

ArrayList<ABlob> blobs = new ArrayList<ABlob>();
ArrayList<ABlob> prevblobs = new ArrayList<ABlob>();

int arraySize = 10; // size of queue for frames to be tracked
BlockingQueue<Integer> times = new ArrayBlockingQueue<Integer>(arraySize);
BlockingQueue<PGraphics> frames = new ArrayBlockingQueue<PGraphics>(arraySize);

int w, h, ledAngle, frame = 0; // frame number
sendTUIO broadcaster = new sendTUIO(); // create our server to send TUIO

boolean pulse = false; // for demo/explanation purposes
boolean startUp = true;

void setup() {
  myPort = new Serial(this, Serial.list()[1], 115200); // connect with the hardware
  myPort.bufferUntil('\n'); // buffer until our newline character

  w = 15; // physical width and height (inches)
  h = 15; 
  displayScale = 30; // how much to blow up the drawings for display
  ledAngle = 80; // LED angle (for simulation)
  size(int(w*displayScale), int(h*displayScale), P2D);

  noSmooth(); // please, more then 3fps

  board = new Board(w, h, ledAngle);
  board.pulse = pulse;
  testBoard(); // create our model of the physical hardware

  buffer = createGraphics(width, height, P2D);

  img = createImage(width, height, RGB);

  // set up tracking
  flob = new Flob(this, img);
  flob.setOm(10).setMinNumPixels(minBlobSize).setMaxNumPixels(maxBlobSize).setTresh(1).setFade(0).setBlur(0);
  stroke(255);
  background(255, 255, 255);
  rectMode(CENTER);

  frameRate(60);
  delay(250); 
}


void draw() {
  if (frames.size() > 1) { // if we have frames, we have business to do
    curFrame = frames.poll();
    int timeAdded = (int)times.poll();
    image(curFrame, 0, 0);
    broadcaster.broadcastBlobs(blobs, frame);
    frame++;
  }
}

void serialEvent(Serial p) {
  int s = millis();
  int id;
  byte[] inBuffer = new byte[12];
  int numRead = p.readBytes(inBuffer);
  if (inBuffer[0] == 65) { // hardware sends the LED id 10 as 65 to avoid triggering buffer
    inBuffer[0] = 10;
  }

  p.clear(); // flush anything extra

  id = int(inBuffer[0]);

  if (numRead != 12) {
    p.write(65);
    p.clear();
    return;
  }
	
  inBuffer[numRead - 1] = 0;	// last byte is always \n, make it zero just to be certain

  PGraphics b = createGraphics(width, height, P2D); // new buffer for the queue
  board.parseBytes(inBuffer); // tell board to update for this LED
  if (inBuffer[0] == 0) { // if full board updated
    makeAFrame(b); // push into queue
  }
  p.write(65); // get the next data from the arduino
}

// generate one frame and pop it into the queue
void makeAFrame(PGraphics thisFrame) {
  thisFrame.beginDraw();
  board.draw(thisFrame, displayScale); // draw the lines from the board object
  thisFrame.endDraw();
  try {
    frames.put(thisFrame);
    times.put(millis());
  }
  catch(Exception e) {
    println("problem?"); // lazy error catching
  }
}

void findBlobs(PGraphics b) {
  boolean stop = false;  
  fastBlurThreshold(b, blurRadius); // blur it
  image(b, 0, 0);
  blobs = flob.calc(get()); // identify blobs
  assignIds(blobs, prevblobs); // match ids to existing ones 

    prevblobs.clear();


  for (int i = 0; i < blobs.size(); i++) {
    ABlob ab = (ABlob)blobs.get(i); 
    fill(0, 0, 255, 100);

    rect(ab.cx, ab.cy, ab.dimx, ab.dimy);
    fill(255, 0, 0);
    text(ab.id, ab.cx-8, ab.cy);
    prevblobs.add((ABlob)blobs.get(i));
  }
}


// simplistic algorithm to persist blob IDs across frames
// also assigns velocity (one frame's worth) to the headx & heady values
// almost certainly a better way to do this, but this was easiest to implement
// of all the schemes I came up with
void assignIds(ArrayList<ABlob> b, ArrayList<ABlob> pb) {
  //println(b.size() + " previous: " + pb.size());
  int i, j, minId=-1, minIndex = -1;
  int maxId=b.size();
  float minDist, curDist;
  ABlob cur, old;

  for (i=0; i<b.size(); i++) { // loop through all current blobs
    minId = -1; // id of minimum distance blob 
    minDist = 10000000; // distance away of min distance (because it's intensive to compute)
    cur = b.get(i);

    for (j=0; j<pb.size(); j++) { // loop through all the old blobs 
      old = pb.get(j);
      curDist = sqrt( pow(cur.cx-old.cx, 2) + pow(cur.cy-old.cy, 2) ); // compute distance
      if (curDist < minDist) { // find the closest, store its info
        minId = old.id; // could just store this
        minIndex=j; // but we'll keep everything for easy access
        minDist = curDist;
      }
    }

    // set the current blobs id to the nearest old one
    // (they're the same)
    if (minId == -1 || minDist > movementThreshold) { // if we ran out of old ones
      cur.id = maxBlob; // set to new id
      maxBlob++; // make next max id
      //println("adding id");
    }
    else {
      //println("setting " + cur.id + " to " + minId);
      cur.id = minId;
      cur.headx = (cur.cx - pb.get(minIndex).cx) * 8 / (w * displayScale);
      cur.heady = (cur.cy - pb.get(minIndex).cy) * 8 / (h * displayScale);
      pb.remove(minIndex); // remove it so we don't give it to two, and to get to n*log n runtime
    }
  }

  if (pb.size() > 0) {
    pb.clear(); // clear previous blobs to store next frames
  }
}

void keyPressed() {
  if (key == UP) { 
    board.clearObstructions();
  }
}

void testBoard() {
  int modulesX = 5;
  int modulesY = 5;

  int sensorPerModule = 4;

  float sensorSpacing = .75;
  float ledSpacing = 3;

  float ledOffset = 1.5;
  float sensorOffset = .375;

  int i;
  // add sources before sensors
  for (i=0; i < modulesY; i++) {
    board.addSource(0, i*ledSpacing+ledOffset);
  }

  for (i=0; i < modulesX; i++) {
    board.addSource(i*ledSpacing+ledOffset, h);
  }  

  for (i=0; i < modulesY; i++) {
    board.addSource(ledSpacing*(modulesX), h-(i*ledSpacing+ledOffset));
  }

  for (i=0; i < modulesX; i++) {
    board.addSource((modulesX - i)*ledSpacing-ledOffset, 0);
  }  

  // add sensors
  for (i=0; i < modulesY * sensorPerModule; i++) {
    board.addSensor(i, 0, i*sensorSpacing+sensorOffset);
  }	

  for (i=0; i < modulesX * sensorPerModule; i++) {
    board.addSensor(i + modulesY * sensorPerModule, i*sensorSpacing+sensorOffset, h);
  }

  for (i=0; i < modulesY * sensorPerModule; i++) {
    board.addSensor(i + modulesX * sensorPerModule + modulesY * sensorPerModule, ledSpacing*(modulesX), h-(i*sensorSpacing+sensorOffset));
  }

  for (i=0; i < modulesX * sensorPerModule; i++) {
    board.addSensor((modulesX * sensorPerModule - 1 - i) + modulesX * sensorPerModule + modulesY * sensorPerModule * 2, i*sensorSpacing+sensorOffset, 0);
  }
}

void simulateBoard() {
  int modulesX = w/3;
  int modulesY = h/3;

  int sensorPerModule = 4;

  float sensorSpacing = .75;
  float ledSpacing = 3;

  float ledOffset = 1.5;
  float sensorOffset = .375;

  int i;
  // add sources before sensors
  for (i=0; i < modulesX; i++) {
    board.addSource(i*ledSpacing+ledOffset, 0);
  }  

  for (i=0; i < modulesY; i++) {
    board.addSource(w, i*ledSpacing+ledOffset);
  }

  for (i=0; i < modulesX; i++) {
    board.addSource(i*ledSpacing+ledOffset, h);
    //println((w-i)*xSpacing+xOffset);
  }  

  for (i=0; i < modulesY; i++) {
    board.addSource(0, i*ledSpacing+ledOffset);
  }


  // add sensors
  for (i=0; i < modulesX * sensorPerModule; i++) {
    board.addSensor(i, i*sensorSpacing+sensorOffset, 0);
  }  

  for (i=0; i < modulesY * sensorPerModule; i++) {
    board.addSensor(i + modulesX * sensorPerModule, w, i*sensorSpacing+sensorOffset);
  }

  for (i=0; i < modulesX * sensorPerModule; i++) {
    board.addSensor(i + modulesX * sensorPerModule + modulesY * sensorPerModule, i*sensorSpacing+sensorOffset, h);
  }  

  for (i=0; i < modulesY * sensorPerModule; i++) {
    board.addSensor(i + modulesX * sensorPerModule *2 + modulesY * sensorPerModule, 0, i*sensorSpacing+sensorOffset);
  }

  board.addObstruction(.4, 7, 5);
}


// ==================================================
// Super Fast Blur v1.1
// by Mario Klingemann <http://incubator.quasimondo.com>
// modifications by Gabe Boning
// ==================================================
void fastBlurThreshold(PImage img, int radius) {

  if (radius < 1) {
    return;
  }
  int w = img.width;
  int h = img.height;
  int wm = w - 1;
  int hm = h - 1;
  int wh = w*h;
  int div = radius + radius + 1;
  int r[] = new int[wh];
  int g[] = new int[wh];
  int b[] = new int[wh];
  int cur;
  int rsum, gsum, bsum, x, y, i, p, p1, p2, yp, yi, yw;
  int vmin[] = new int[max(w, h)];
  int vmax[] = new int[max(w, h)];

  int[] pix = img.pixels;
  int dv[] = new int[256*div];
  for (i = 0; i < 256*div; i++) {
    dv[i] = (i / div);
  }

  yw = yi = 0;

  for (y = 0; y < h; y++) {
    rsum = gsum = bsum = 0;
    for (i = -radius; i <= radius; i++) {
      p = pix[yi + min(wm, max(i, 0))];
      cur = (p & 0xff0000)>>16;
      rsum += cur;
    }
    for (x = 0; x < w; x++) {

      r[yi] = dv[rsum];

      if (y == 0) {
        vmin[x] = min(x + radius + 1, wm);
        vmax[x] = max(x - radius, 0);
      }
      p1 = pix[yw + vmin[x]];
      p2 = pix[yw + vmax[x]];

      rsum += ((p1 & 0xff0000) - (p2 & 0xff0000))>>16;
      yi++;
    }
    yw += w;
  }

  for (x = 0; x < w; x++) {
    rsum = gsum = bsum = 0;
    yp =- radius*w;
    for (i = -radius; i <= radius; i++) {
      yi = max(0, yp) + x;
      rsum += r[yi];
      yp += w;
    }
    yi = x;
    for (y = 0; y < h; y++) {
      //pix[yi] = 0xff000000 | (dv[rsum]<<16) | (dv[rsum]<<8) | dv[rsum]; // where the actual setting happens
      //if(y%100 == 0) {	println(dv[rsum]); }
      if (dv[rsum] > thresh) {
        pix[yi] = 0xffffffff;
      }
      else {
        pix[yi] = 0xff000000;
      }
      if (x == 0) {
        vmin[y] = min(y + radius + 1, hm)*w;
        vmax[y] = max(y - radius, 0)*w;
      }
      p1 = x + vmin[y];
      p2 = x + vmax[y];

      rsum += r[p1] - r[p2];

      yi += w;
    }
  }
}

void delay(int ms) {
  int current_time = millis();
  while (millis () - current_time < ms);
}

