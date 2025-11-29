#include <Arduino.h>
#include <SPI.h>
#include <Ethernet.h>
#include <ESP_SSLClient.h>
#define ENABLE_USER_AUTH
#define ENABLE_DATABASE
#ifndef FIREBASE_SSE_TIMEOUT_MS
  #define FIREBASE_SSE_TIMEOUT_MS 45000
#endif
#include <FirebaseClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <RTClib.h>    
#include <LoRa_E32.h>
#include <EthernetUdp.h>
#include <Dns.h>

// ================== CONFIG ==================
#define DEBUG 1
#define NET_TESTS 0

// Ethernet W5500 
#define WIZNET_CS_PIN   5
#define WIZNET_RST_PIN  26

#define USE_DHCP 1
#if !USE_DHCP
IPAddress ETH_IP      (192,168,137,50);
IPAddress ETH_GATEWAY (192,168,137,1);
IPAddress ETH_SUBNET  (255,255,255,0);
IPAddress ETH_DNS     (192,168,137,1);
#endif
byte ETH_MAC[] = {0x02, 0xF0, 0x0D, 0xBE, 0xEF, 0x01};

#ifndef D2
  // Fallback: nhiều board ESP32 không định nghĩa D2 -> dùng GPIO2
  #define D2 2
#endif
#define LED_ETH_PIN D2

// Firebase
static const char* API_KEY      = "AIzaSyB4cV8O1H_wefIecQ2f_bfZuHB6IKn8-DQ";
static const char* DATABASE_URL = "https://demo1-5c0de-default-rtdb.asia-southeast1.firebasedatabase.app";
static const char* USER_EMAIL   = "p@gmail.com";
static const char* USER_PASS    = "123456";

LoRa_E32 lora(&Serial2, 9600);

// ================== GLOBALS ==================
static bool g_stream_N01 = false;
static bool g_stream_N02 = false;
static bool g_eth_ready = false;
static bool g_fb_ready  = false;
static inline bool gatewayReady() { return g_eth_ready && g_fb_ready; }
static uint32_t g_led_tick = 0;
static bool     g_led_on   = false;

RTC_DS3231 rtc;
bool g_rtc_present  = false;
bool g_rtc_has_time = false;

EthernetClient eth_s1;
EthernetClient eth_s2;
EthernetClient eth_client;
ESP_SSLClient  ssl_client;

using AsyncClient = AsyncClientClass;
AsyncClient      aClient(ssl_client);
FirebaseApp      app;
RealtimeDatabase Database;
UserAuth         userAuth(API_KEY, USER_EMAIL, USER_PASS, 3000);

// Mỗi node 1 stream client
ESP_SSLClient ssl_stream_N01, ssl_stream_N02;
AsyncClient   aStreamN01(ssl_stream_N01), aStreamN02(ssl_stream_N02);

// Node LoRa fixed addressing
struct NodeLoraCfg { const char* nodeId; uint8_t addh, addl, ch; };
static NodeLoraCfg NODES[] = {
  {"N01", 0x00, 0x03, 0x17},
  {"N02", 0x00, 0x04, 0x17},
};
static const size_t NODES_N = sizeof(NODES)/sizeof(NODES[0]);

// ====== SCHEDULE CONFIG (pump/light/fan) ======
enum DeviceIndex { DEV_PUMP = 0, DEV_LIGHT = 1, DEV_FAN = 2, DEV_COUNT = 3 };
static const char *DEVICE_KEYS[DEV_COUNT] = {"pump", "light", "fan"};

struct DeviceScheduleCfg {
  bool enabled;
  int  onMinutes;   // phút trong ngày 0..1439, -1 = không cấu hình
  int  offMinutes;  // phút trong ngày 0..1439, -1 = không cấu hình
  int  lastApplied; // -1 = chưa từng gửi, 0 = OFF, 1 = ON (do lịch)
};

static DeviceScheduleCfg g_schedules[NODES_N][DEV_COUNT];
static bool g_schedLoaded[NODES_N];


static bool getLoraAddr(const String& nodeId, uint8_t& addh, uint8_t& addl, uint8_t& ch) {
  for (size_t i=0;i<NODES_N;i++) {
    if (nodeId.equalsIgnoreCase(NODES[i].nodeId)) {
      addh = NODES[i].addh; addl = NODES[i].addl; ch = NODES[i].ch; return true;
    }
  }
  return false;
}

struct PendingCmd {
  bool     used;
  String   nodeId;
  String   device;
  int      value;       // 0/1
  String   cmdId;       // ví dụ N01-1a2b (ngắn, dễ debug)
  uint8_t  retryCount;  // đã gửi bao nhiêu lần
  uint32_t lastSentMs;  // millis() lần gửi gần nhất
  bool     done;        // đã nhận ACK
};

static const uint8_t MAX_PENDING_CMDS = 8;
static PendingCmd g_cmdQueue[MAX_PENDING_CMDS];
static uint32_t   g_cmdCounter = 0;   // sinh cmdId

static int findFreeCmdSlot() {
  for (uint8_t i = 0; i < MAX_PENDING_CMDS; ++i) {
    if (!g_cmdQueue[i].used) return i;
  }
  return -1;
}

static int findCmdById(const String& cmdId) {
  for (uint8_t i = 0; i < MAX_PENDING_CMDS; ++i) {
    if (g_cmdQueue[i].used && g_cmdQueue[i].cmdId == cmdId) return i;
  }
  return -1;
}

// ===== Forward declarations =====
static inline String nodePathFromId(const String &nodeId, const String &tail);
static inline String downlinkPath(const String& nodeId); //Xử lý đường dẫn downlink của các Node tới RTDB
static void markDownlink(const String& nodeId, const String& cmdId, const char* status, const char* err = nullptr); //Xử lý ghi lệnh lên RTDB
static bool sendDeviceCmd_LoRa(const String& nodeId, const String& device, int value);
static void handleDownlinkPayload(const String& nodeId, const String& childPath, const String& payload); //Xử lý 1 child của /nodes/<id>/downlink
static void processDownlinkStream(AsyncResult &aResult);

// ================== ETH ==================
static inline void wizReset() {
  pinMode(WIZNET_RST_PIN, OUTPUT);
  digitalWrite(WIZNET_RST_PIN, HIGH); delay(200);
  digitalWrite(WIZNET_RST_PIN, LOW);  delay(50);
  digitalWrite(WIZNET_RST_PIN, HIGH); delay(200);
}
static bool startEthernet() {
#if DEBUG
  Serial.println("[ETH] Reset W5500...");
#endif
  wizReset();
  Ethernet.init(WIZNET_CS_PIN);
#if DEBUG
  Serial.println("[ETH] Ethernet.begin...");
#endif
#if USE_DHCP
  if (Ethernet.begin(ETH_MAC) == 0) {
#if DEBUG
    Serial.println("[ETH] DHCP failed");
#endif
    g_eth_ready = false;
    return false;
  }
#else
  Ethernet.begin(ETH_MAC, ETH_IP, ETH_DNS, ETH_GATEWAY, ETH_SUBNET);
#endif
  {
    unsigned long t0 = millis();
    while (Ethernet.linkStatus() != LinkON && millis() - t0 < 3000) delay(100);
  }
  if (Ethernet.linkStatus() != LinkON) {
#if DEBUG
    Serial.println("[ETH] Link OFF");
#endif
    g_eth_ready = false;
    return false;
  }
#if DEBUG
  Serial.print("[ETH] IP: "); Serial.println(Ethernet.localIP());
#endif
  g_eth_ready = true;
  return true;
}

// ================== TIME/HELPERS ==================
static const int32_t TZ_OFFSET_SECONDS = 7 * 3600;
static inline uint64_t nowUnix() {
  if (g_rtc_present && g_rtc_has_time) {
    DateTime now = rtc.now();
    return (uint64_t)now.unixtime();
  }
  return (uint64_t)(millis() / 1000UL);
}
static inline String nodePathFromId(const String &nodeId, const String &tail) {
  String nid = nodeId;
  if (nid.length() > 0 && (nid[0] == 'N' || nid[0] == 'n')) {
    return String("/nodes/") + nid + tail;
  }
  if (nid.length() == 1) nid = "N0" + nid;
  else                  nid = "N"  + nid;
  return String("/nodes/") + nid + tail;
}
static inline void printRtcTimeLine() {
  if (g_rtc_present && g_rtc_has_time) {
    DateTime utc = rtc.now();
    DateTime local = utc + TimeSpan(TZ_OFFSET_SECONDS);
    Serial.printf("[TIME] %04d-%02d-%02d %02d:%02d:%02d\n",
                  local.year(), local.month(), local.day(),
                  local.hour(), local.minute(), local.second());
  } else {
    Serial.println("[TIME] N/A");
  }
}

// ===== NTP sync (Ethernet W5500) =====
static EthernetUDP ntpUDP;

static bool hostByNameCompat(const char* host, IPAddress &ip) {
  IPAddress dns = Ethernet.dnsServerIP();
  if (dns == IPAddress(0,0,0,0)) {
    dns = IPAddress(8,8,8,8);
  }
  DNSClient dnsClient;
  dnsClient.begin(dns);
  int ret = dnsClient.getHostByName(host, ip);  
  return ret == 1;
}


static bool syncRtcViaNTP(uint16_t localPort = 2390, uint16_t timeoutMs = 1500) {
  static const char* SERVERS[] = { "time.google.com", "time.cloudflare.com", "pool.ntp.org" };
  static const int N = sizeof(SERVERS)/sizeof(SERVERS[0]);
  const int NTP_PACKET_SIZE = 48;
  byte buf[NTP_PACKET_SIZE];

  if (!ntpUDP.begin(localPort)) return false;

  for (int i = 0; i < N; ++i) {
    IPAddress ntpIP;
    if (!hostByNameCompat(SERVERS[i], ntpIP)) continue;

    memset(buf, 0, NTP_PACKET_SIZE);
    buf[0] = 0b11100011; // LI=3, VN=4, Mode=3 (client)
    buf[1] = 0; buf[2] = 6; buf[3] = 0xEC;
    buf[12]=49; buf[13]=0x4E; buf[14]=49; buf[15]=52;

    ntpUDP.beginPacket(ntpIP, 123);
    ntpUDP.write(buf, NTP_PACKET_SIZE);
    ntpUDP.endPacket();

    uint32_t t0 = millis();
    while ((millis() - t0) < timeoutMs) {
      int len = ntpUDP.parsePacket();
      if (len >= NTP_PACKET_SIZE) {
        ntpUDP.read(buf, NTP_PACKET_SIZE);
        unsigned long secs1900 =
          ((unsigned long)buf[40] << 24) |
          ((unsigned long)buf[41] << 16) |
          ((unsigned long)buf[42] <<  8) |
          ((unsigned long)buf[43]);
        const unsigned long NTP_UNIX_DELTA = 2208988800UL; // 1900→1970
        time_t epoch = (time_t)(secs1900 - NTP_UNIX_DELTA); // UTC seconds

        if (g_rtc_present) {
          time_t rtc_now = (time_t)rtc.now().unixtime();
          if (labs((long)epoch - (long)rtc_now) < 5) {
            ntpUDP.stop();
            return true;
          }
        }

        rtc.adjust(DateTime(epoch));
        ntpUDP.stop();
        return true;
      }
      delay(10);
    }
  }

  ntpUDP.stop();
  return false;
}
// ================== RTDB WRAPPERS ==================
static bool writeStatus(const String &nodeId, float t, float h, float s, float l, uint64_t ts,
                        int eco2, int tvoc, int aqi) {
  JsonWriter w; object_t json, o1,o2,o3,o4,o5,o6,o7,o8;
  w.create(o1, "t",  t);  w.create(o2, "h", h);
  w.create(o3, "s",  s);  w.create(o4, "l", l);
  w.create(o5, "ts", (double)ts);
  w.create(o6, "ec", eco2); w.create(o7, "tv", tvoc); w.create(o8, "aq", aqi);
  w.join(json, 8, o1,o2,o3,o4,o5,o6,o7,o8);
  String path = nodePathFromId(nodeId, "/status");
  return Database.set<object_t>(aClient, path, json);
}
static bool pushTelemetryFromDoc(const String &nodeId,
                                 float t, float h, float s, float l, uint64_t ts, const String &nStr,
                                 int eco2, int tvoc, int aqi) {
  JsonWriter w; object_t json, o1,o2,o3,o4,o5,o6,o7,o8,o9;
  int nInt = nStr.toInt();
  w.create(o1, "n",  nInt);  w.create(o2, "t",  t);  w.create(o3, "h",  h);
  w.create(o4, "s",  s);     w.create(o5, "l",  l);  w.create(o6, "ts", (double)ts);
  w.create(o7, "ec", eco2);  w.create(o8, "tv", tvoc); w.create(o9, "aq", aqi);
  w.join(json, 9, o1,o2,o3,o4,o5,o6,o7,o8,o9);
  String path = nodePathFromId(nStr, "/telemetry");
  return Database.push<object_t>(aClient, path, json);
}

// ================== UPLINK (LoRa -> Firebase) ==================
static inline void printSensorLine(const String& nid, float t, float h, float s, float l,
                                   int eco2, int tvoc, int aqi, uint64_t ts) {
#if DEBUG
  Serial.printf("[DATA] N%s  t=%.2f°C  h=%.2f%%  s=%.2f  l=%.2f  ec=%dppm  tv=%dppb  aqi=%d  ts=%llu\n",
                nid.c_str(), t, h, s, l, eco2, tvoc, aqi, (unsigned long long)ts);
#endif
}
static void handleUplinkPacket(const String &pkt) {
  String s = pkt; s.trim();
  if (s.length() == 0) return;

  if (s[0] == '[') {                 // format mới: array
    StaticJsonDocument<192> doc; if (deserializeJson(doc, s)) return;
    JsonArray a = doc.as<JsonArray>(); if (a.size() < 9) return;
    int   n    = a[0] | 0;
    float t    = (a[1] | 0) / 10.0f;
    float h    = (a[2] | 0) / 10.0f;
    float so   = (a[3] | 0) / 10.0f;
    float l    = a[4] | 0;
    int   eco2 = a[5] | 0;
    int   tvoc = a[6] | 0;
    int   aqi  = a[7] | 0;
    uint64_t ts= a[8] | 0;
    String nodeId = String(n);
    printSensorLine(nodeId, t, h, so, l, eco2, tvoc, aqi, ts);
    printRtcTimeLine();
    bool ok1 = writeStatus(nodeId, t, h, so, l, ts, eco2, tvoc, aqi);
    bool ok2 = pushTelemetryFromDoc(nodeId, t, h, so, l, ts, nodeId, eco2, tvoc, aqi);
    Serial.println((ok1 && ok2) ? "[PUSH] OK" : "[PUSH] FAIL");
    return;
  }

    if (s[0] == '{') {                 // format cũ: object
    StaticJsonDocument<512> doc; 
    if (deserializeJson(doc, s)) return;

    // ===== ACK từ node điều khiển =====
    // Dạng: {"ok":true,"id":"N01-1a2b","device":"pump","value":1}
    if (doc.containsKey("ok")) {
      const char* id = doc["id"] | "";
      if (!id || !id[0]) {
        // ACK kiểu cũ không có id -> bỏ qua
        return;
      }
      String cmdId = String(id);

#if DEBUG
      Serial.printf("[ACK] cmdId=%s\n", cmdId.c_str());
#endif
      int idx = findCmdById(cmdId);
      if (idx >= 0) {
        g_cmdQueue[idx].done = true;
#if DEBUG
        Serial.printf("[ACK] mark cmd %s done (slot=%d)\n",
                      cmdId.c_str(), idx);
#endif
      }
      return; // không xử lý như gói cảm biến
    }

    if (!doc.containsKey("n") || !doc.containsKey("t") || !doc.containsKey("h") ||
        !doc.containsKey("s") || !doc.containsKey("l")) return;


    String   nodeId = doc["n"].as<String>();
    float    t      = doc["t"] | 0.0f;
    float    h      = doc["h"] | 0.0f;
    float    so     = doc["s"] | 0.0f;
    float    l      = doc["l"] | 0.0f;
    uint64_t ts     = doc.containsKey("ts") ? (uint64_t)doc["ts"].as<uint64_t>() : nowUnix();
    int eco2 = doc["ec"] | 0, tvoc = doc["tv"] | 0, aqi = doc["aq"] | 0;

    printSensorLine(nodeId, t, h, so, l, eco2, tvoc, aqi, ts);
    printRtcTimeLine();
    bool ok1 = writeStatus(nodeId, t, h, so, l, ts, eco2, tvoc, aqi);
    bool ok2 = pushTelemetryFromDoc(nodeId, t, h, so, l, ts, nodeId, eco2, tvoc, aqi);
    Serial.println((ok1 && ok2) ? "[PUSH] OK" : "[PUSH] FAIL");
  }
}

// ================== DOWNLINK ==================
static inline String downlinkPath(const String& nodeId) {
  return nodePathFromId(nodeId, "/downlink");
}
static void markDownlink(const String& nodeId, const String& cmdId,
                         const char* status, const char* err /*=nullptr*/) {
  String p = downlinkPath(nodeId) + "/" + cmdId;
  JsonWriter w; object_t root, s, e, gw;
  w.create(s, "status", status);
  if (err) w.create(e, "errorMsg", err);
  w.create(gw, "gwTs", (double)nowUnix());
  if (err) w.join(root, 3, s, e, gw);
  else     w.join(root, 2, s, gw);
  Database.update<object_t>(aClient, p, root);
}


bool sendDeviceCmd_LoRa(const String& nodeId, const String& device, int value) {
  int idx = findFreeCmdSlot();
  if (idx < 0) {
#if DEBUG
    Serial.println("[CMDQ] Queue full, drop command");
#endif
    return false;
  }

  PendingCmd &c = g_cmdQueue[idx];
  c.used       = true;
  c.nodeId     = nodeId;
  c.device     = device;
  c.value      = value ? 1 : 0;
  c.retryCount = 0;
  c.lastSentMs = 0;
  c.done       = false;

  g_cmdCounter++;
  // cmdId dạng: N01-1a2b (ngắn, dễ debug, vẫn < 58 byte khi serialize)
  c.cmdId = nodeId + "-" + String((uint16_t)(g_cmdCounter & 0xFFFF), HEX);

#if DEBUG
  Serial.printf("[CMDQ] Enqueue cmd %s dev=%s val=%d (slot=%d)\n",
                c.cmdId.c_str(), c.device.c_str(), c.value, idx);
#endif

  // Việc gửi thực tế sẽ do processCommandQueue() đảm nhiệm trong loop()
  return true;
}


static void handleDownlinkPayload(const String& nodeId,
                                  const String& childPath,
                                  const String& payload)
{
  // Chỉ quan tâm tới /batch (đúng với app hiện tại)
  if (childPath != "/batch") {
    Serial.printf("[DL][%s] Ignore childPath=%s\n",
                  nodeId.c_str(), childPath.c_str());
    return;
  }

  StaticJsonDocument<768> d;
  DeserializationError err = deserializeJson(d, payload);
  if (err) {
    Serial.printf("[DL][%s] JSON error: %s\n",
                  nodeId.c_str(), err.c_str());
    return;
  }

  JsonObject root = d.as<JsonObject>();
  if (root.isNull()) {
    Serial.printf("[DL][%s] root is null\n", nodeId.c_str());
    return;
  }

  const char* cmd    = root["cmd"]    | "";
  const char* status = root["status"] | "pending";

  // Lấy cmdId từ childPath: "/batch" -> "batch"
  String cmdId = childPath;
  if (cmdId.startsWith("/")) cmdId.remove(0, 1);

  // Chỉ xử lý khi cmd là setMulti (hoặc set_multi tuỳ em đặt)
  // và status còn "pending" hoặc rỗng
  if (strcasecmp(cmd, "setMulti") != 0) {
    Serial.printf("[DL][%s] Unknown cmd=%s\n",
                  nodeId.c_str(), cmd);
    return;
  }
  if (!(status[0] == 0 || strcasecmp(status, "pending") == 0)) {
    Serial.printf("[DL][%s] Skip, status=%s\n",
                  nodeId.c_str(), status);
    return;
  }

  // Lấy mảng payload
  JsonArray arr = root["payload"].as<JsonArray>();
  if (arr.isNull() || arr.size() == 0) {
    Serial.printf("[DL][%s] Empty payload\n", nodeId.c_str());
    // đánh dấu done nhưng ghi chú lỗi
    markDownlink(nodeId, cmdId, "done", "empty payload");
    return;
  }

  // Đánh dấu đã nhận batch
  markDownlink(nodeId, cmdId, "received", nullptr);

  const uint32_t GAP_MS = 2000; // giãn cách 2 giây giữa các lệnh
  int total  = arr.size();
  int okCnt  = 0;

  Serial.printf("[DL][%s] setMulti với %d item\n",
                nodeId.c_str(), total);

  for (JsonObject it : arr) {
    const char* dev = it["device"] | "";
    int value       = it["value"]  | -1;

    if (!dev || !dev[0] || (value != 0 && value != 1)) {
      Serial.printf("[DL][%s] Skip item (dev/value invalid)\n",
                    nodeId.c_str());
      continue;
    }

    bool on = (value != 0);
    Serial.printf("[DL][%s] -> LoRa: device=%s, value=%d\n",
                  nodeId.c_str(), dev, on);

    // GỬI LỆNH ĐƠN DẠNG {"cmd":"set","device":"pump","value":1}
    // Hàm này bên dưới đã build JSON nhỏ (<58 byte) và gửi qua LoRa E32
    bool ok = sendDeviceCmd_LoRa(nodeId, String(dev), on);
    if (ok) {
      okCnt++;
    } else {
      Serial.printf("[DL][%s] sendDeviceCmd_LoRa FAIL\n",
                    nodeId.c_str());
    }

    // Giãn cách 2s cho lần lệnh tiếp theo
    delay(GAP_MS);
  }

  // Cập nhật trạng thái cuối cùng cho batch
  if (okCnt == total) {
    markDownlink(nodeId, cmdId, "done", nullptr);
  } else if (okCnt == 0) {
    markDownlink(nodeId, cmdId, "error", "no item applied");
  } else {
    char buf[64];
    snprintf(buf, sizeof(buf), "applied %d/%d", okCnt, total);
    markDownlink(nodeId, cmdId, "done", buf);
  }
}

// Gửi các lệnh trong hàng đợi (gọi định kỳ trong loop)
static void processCommandQueue() {
  if (!gatewayReady()) return;

  const uint8_t  MAX_RETRY          = 3;
  const uint32_t RETRY_INTERVAL_MS  = 2000;

  uint32_t now = millis();

  for (uint8_t i = 0; i < MAX_PENDING_CMDS; ++i) {
    PendingCmd &c = g_cmdQueue[i];
    if (!c.used) continue;

    // Nếu đã ACK thì giải phóng slot
    if (c.done) {
#if DEBUG
      Serial.printf("[CMDQ] cmd %s done, free slot %d\n",
                    c.cmdId.c_str(), i);
#endif
      c.used = false;
      continue;
    }

    // Quá số lần retry -> bỏ
    if (c.retryCount >= MAX_RETRY) {
#if DEBUG
      Serial.printf("[CMDQ] cmd %s reach max retry, drop\n",
                    c.cmdId.c_str());
#endif
      c.used = false;
      continue;
    }

    // Chưa đến thời điểm gửi lại
    if (c.retryCount > 0 && (now - c.lastSentMs) < RETRY_INTERVAL_MS) {
      continue;
    }

    uint8_t addh, addl, ch;
    if (!getLoraAddr(c.nodeId, addh, addl, ch)) {
#if DEBUG
      Serial.printf("[CMDQ] Unknown nodeId %s\n", c.nodeId.c_str());
#endif
      c.used = false;
      continue;
    }

    StaticJsonDocument<96> d;
    d["cmd"]    = "set";
    d["device"] = c.device;
    d["value"]  = c.value ? 1 : 0;
    d["id"]     = c.cmdId; // để node ACK lại đúng lệnh
    String payload;
    serializeJson(d, payload);

    // Giới hạn E32: 58 byte
    if (payload.length() > 58) {
#if DEBUG
      Serial.printf("[CMDQ] payload too long (%d), drop\n",
                    payload.length());
#endif
      c.used = false;
      continue;
    }

    ResponseStatus rs = lora.sendFixedMessage(addh, addl, ch, payload);
#if DEBUG
    Serial.printf("[CMDQ] send cmd %s to %s dev=%s val=%d rs=%d\n",
                  c.cmdId.c_str(),
                  c.nodeId.c_str(),
                  c.device.c_str(),
                  c.value,
                  rs.code);
#endif

    c.lastSentMs = now;
    c.retryCount++;

    // Mỗi vòng loop chỉ gửi 1 lệnh để tránh nghẽn
    break;
  }
}


// ===== Stream callback (đúng theo ví dụ API bạn gửi) =====
static void processDownlinkStream(AsyncResult &aResult) {
  if (!aResult.isResult()) return;  // không có gì để đọc

  if (aResult.isEvent()) {
#if DEBUG
    Firebase.printf("Event task: %s, msg: %s, code: %d\n",
      aResult.uid().c_str(), aResult.eventLog().message().c_str(), aResult.eventLog().code());
#endif
  }
  if (aResult.isDebug()) {
#if DEBUG
    //Firebase.printf("Debug task: %s, msg: %s\n", aResult.uid().c_str(), aResult.debug().c_str());
#endif
  }
  if (aResult.isError()) {
#if DEBUG
    Firebase.printf("Error task: %s, msg: %s, code: %d\n",
      aResult.uid().c_str(), aResult.error().message().c_str(), aResult.error().code());
#endif
  }

  if (!aResult.available()) return;

  RealtimeDatabaseResult &res = aResult.to<RealtimeDatabaseResult>();
  if (res.isStream()) {
    // uid = "dl_N01" hoặc "dl_N02" mà ta gán khi đăng ký
    String uid = aResult.uid();
    String nodeId;
    if      (uid == "dl_N01") nodeId = "N01";
    else if (uid == "dl_N02") nodeId = "N02";
    else {
      // Nếu bạn thêm node khác, map thêm ở đây
      return;
    }

    String childPath = res.dataPath();
if (childPath == "/") return;

const char* payload = res.to<const char *>();
// --- CHẶN payload rỗng / null ---
if (!payload || payload[0] == '\0' || (strcmp(payload, "null") == 0)) {
  return;
}

#if DEBUG
StaticJsonDocument<256> jd;
if (!deserializeJson(jd, payload)) {
  const char* status = jd["status"] | "";
  const char* cmd    = jd["cmd"]    | "";
  if ((status[0] == 0 || strcasecmp(status, "pending") == 0) &&
      (strcasecmp(cmd, "setMulti") == 0)) {
    Serial.printf("[RX] %s/batch setMulti (%u items)\n",
                  nodeId.c_str(),
                  jd["payload"].is<JsonArray>() ? jd["payload"].as<JsonArray>().size() : 0);
  }
}
#endif
handleDownlinkPayload(nodeId, childPath, String(payload));
  }
  else {
    // Không phải stream (ví dụ response lần đầu "get" nếu không bật filter)
#if DEBUG
    Firebase.printf("task: %s, payload: %s\n", aResult.uid().c_str(), aResult.c_str());
#endif
  }
}
// ================== SCHEDULE HELPERS ==================

static void initSchedules() {
  for (size_t i = 0; i < NODES_N; ++i) {
    for (int d = 0; d < DEV_COUNT; ++d) {
      g_schedules[i][d].enabled     = false;
      g_schedules[i][d].onMinutes   = -1;
      g_schedules[i][d].offMinutes  = -1;
      g_schedules[i][d].lastApplied = -1;
    }
    g_schedLoaded[i] = false;
  }
}

// Chuỗi 'HH:mm' -> phút trong ngày (0..1439)
static bool parseHHmmToMinutes(const String &s, int &outMinutes) {
  int colon = s.indexOf(':');
  if (colon <= 0) return false;
  int h = s.substring(0, colon).toInt();
  int m = s.substring(colon + 1).toInt();
  if (h < 0 || h > 23 || m < 0 || m > 59) return false;
  outMinutes = h * 60 + m;
  return true;
}

// Đọc /nodes/{id}/schedules từ Firebase về RAM
static bool loadSchedulesForNodeIndex(size_t idx) {
  if (idx >= NODES_N) return false;
  const char *nodeId = NODES[idx].nodeId;
  String path = nodePathFromId(String(nodeId), "/schedules");

#if DEBUG
  Serial.printf("[SCH][%s] get schedules: %s\n", nodeId, path.c_str());
#endif

  String json = Database.get<String>(aClient, path);
  if (aClient.lastError().code() != 0) {
#if DEBUG
    Serial.printf("[SCH][%s] get() error %d: %s\n",
                  nodeId,
                  aClient.lastError().code(),
                  aClient.lastError().message().c_str());
#endif
    return false;
  }

  if (json.length() == 0 || json == "null") {
#if DEBUG
    Serial.printf("[SCH][%s] no schedule data\n", nodeId);
#endif
    // Không xoá cấu hình cũ, chỉ báo chưa load
    g_schedLoaded[idx] = false;
    return false;
  }

  StaticJsonDocument<512> doc;
  DeserializationError err = deserializeJson(doc, json);
  if (err) {
#if DEBUG
    Serial.printf("[SCH][%s] JSON parse error: %s\n",
                  nodeId, err.c_str());
#endif
    return false;
  }

  for (int d = 0; d < DEV_COUNT; ++d) {
    const char *key = DEVICE_KEYS[d];
    DeviceScheduleCfg &cfg = g_schedules[idx][d];

    cfg.enabled     = false;
    cfg.onMinutes   = -1;
    cfg.offMinutes  = -1;
    cfg.lastApplied = -1;

    if (!doc.containsKey(key)) continue;
    JsonVariant v = doc[key];
    if (!v.is<JsonObject>()) continue;
    JsonObject o = v.as<JsonObject>();

    cfg.enabled = o["enabled"] | false;

    const char *onStr  = o["on"]  | "";
    const char *offStr = o["off"] | "";

    int mins;
    if (onStr && onStr[0]) {
      if (parseHHmmToMinutes(String(onStr), mins)) cfg.onMinutes = mins;
    }
    if (offStr && offStr[0]) {
      if (parseHHmmToMinutes(String(offStr), mins)) cfg.offMinutes = mins;
    }

#if DEBUG
    if (cfg.enabled && cfg.onMinutes >= 0 && cfg.offMinutes >= 0) {
      Serial.printf("[SCH][%s] %s enabled: on=%d, off=%d (min)\n",
                    nodeId, key, cfg.onMinutes, cfg.offMinutes);
    }
#endif
  }

  g_schedLoaded[idx] = true;
  return true;
}

// Gọi định kỳ để reload lịch từ Firebase (ví dụ 30s/lần)
static void pollSchedulesFromFirebase() {
  static uint32_t lastPoll = 0;
  const uint32_t POLL_INTERVAL_MS = 30000;

  uint32_t nowMs = millis();
  if (nowMs - lastPoll < POLL_INTERVAL_MS) return;
  lastPoll = nowMs;

  if (!gatewayReady()) return;

  for (size_t i = 0; i < NODES_N; ++i) {
    loadSchedulesForNodeIndex(i);
  }
}

// Thực thi lịch: quyết định ON/OFF và gửi lệnh xuống node
static void evaluateSchedules() {
  if (!gatewayReady()) return;
  if (!g_rtc_present || !g_rtc_has_time) return;

  static uint32_t lastEval = 0;
  const uint32_t EVAL_INTERVAL_MS = 1000; // kiểm tra 1s/lần

  uint32_t nowMs = millis();
  if (nowMs - lastEval < EVAL_INTERVAL_MS) return;
  lastEval = nowMs;

  uint64_t unixNow = nowUnix();
  // Đổi sang giờ địa phương Việt Nam
  uint32_t secLocal = (uint32_t)((unixNow + TZ_OFFSET_SECONDS) % 86400ULL);
  int minuteOfDay = secLocal / 60;

  for (size_t i = 0; i < NODES_N; ++i) {
    if (!g_schedLoaded[i]) continue;
    const String nodeId = String(NODES[i].nodeId);

    // Đọc mode hiện tại của từng thiết bị từ /controls
    String devModes[DEV_COUNT];
    {
      String ctrlPath = nodePathFromId(nodeId, "/controls");
#if DEBUG
      Serial.printf("[SCH][%s] get controls (for mode): %s\n",
                    nodeId.c_str(), ctrlPath.c_str());
#endif
      String ctrlJson = Database.get<String>(aClient, ctrlPath);
      if (aClient.lastError().code() == 0 &&
          ctrlJson.length() > 0 && ctrlJson != "null") {
        StaticJsonDocument<256> cdoc;
        DeserializationError cerr = deserializeJson(cdoc, ctrlJson);
        if (!cerr) {
          for (int d = 0; d < DEV_COUNT; ++d) {
            String modeKey = String(DEVICE_KEYS[d]) + "Mode";
            const char* mm = cdoc[modeKey.c_str()] | "";
            if (mm && mm[0]) {
              devModes[d] = String(mm);
            }
          }
        }
      }
    }

    for (int d = 0; d < DEV_COUNT; ++d) {
      DeviceScheduleCfg &cfg = g_schedules[i][d];

      // Kiểm tra mode: chỉ chạy lịch khi mode == "schedule" (hoặc chưa set)
      String mode = devModes[d];
      if (mode.length() > 0 && mode != "schedule") {
#if DEBUG
        Serial.printf("[SCH][%s] skip %s by mode=%s\n",
                      nodeId.c_str(), DEVICE_KEYS[d], mode.c_str());
#endif
        continue;
      }

      if (!cfg.enabled) continue;
      if (cfg.onMinutes < 0 || cfg.offMinutes < 0) continue;
      if (cfg.onMinutes == cfg.offMinutes) continue; // cấu hình sai

      bool shouldOn = false;
      int onMin  = cfg.onMinutes;
      int offMin = cfg.offMinutes;

      if (onMin < offMin) {
        // Khoảng trong cùng 1 ngày, ví dụ 06:30 -> 06:45
        shouldOn = (minuteOfDay >= onMin && minuteOfDay < offMin);
      } else {
        // Khoảng qua đêm, ví dụ 22:00 -> 05:00
        shouldOn = (minuteOfDay >= onMin || minuteOfDay < offMin);
      }

      int newState = shouldOn ? 1 : 0;
      if (cfg.lastApplied == newState) continue; // không thay đổi

      cfg.lastApplied = newState;

      const char *devKey = DEVICE_KEYS[d];

#if DEBUG
      Serial.printf("[SCH][%s] %s -> %s (minute=%d)\n",
                    nodeId.c_str(),
                    devKey,
                    newState ? "ON" : "OFF",
                    minuteOfDay);
#endif

      // 1) Cập nhật /nodes/{id}/controls
      {
        String ctrlPath = nodePathFromId(nodeId, "/controls");
        JsonWriter w; object_t root, f1;
        w.create(f1, devKey, newState != 0);
        w.join(root, 1, f1);
        Database.update<object_t>(aClient, ctrlPath, root);
      }

      // 2) Cập nhật /nodes/{id}/meta (updatedBy = schedule)
      {
        String metaPath = nodePathFromId(nodeId, "/meta");
        JsonWriter w; object_t root, m1, m2;
        uint64_t tsMs = nowUnix() * 1000ULL; // epoch millis (gần đúng)
        w.create(m1, "updatedBy", "schedule");
        w.create(m2, "updatedAt", (double)tsMs);
        w.join(root, 2, m1, m2);
        Database.update<object_t>(aClient, metaPath, root);
      }

      // 3) Gửi lệnh LoRa (thực tế là enqueue vào hàng đợi)
      bool ok = sendDeviceCmd_LoRa(nodeId, devKey, newState);
#if DEBUG
      if (!ok) {
        Serial.printf("[SCH][%s] sendDeviceCmd_LoRa FAIL for %s\n",
                      nodeId.c_str(), devKey);
      }
#endif
    }
  }
}


// ================== SETUP / LOOP ==================
void setup() {
#if DEBUG
  Serial.begin(9600);
  delay(100);
  Serial.println("\n[BOOT] LoRa → Firebase via Ethernet (W5500) + ESP_SSLClient + RTDB Stream ");
  pinMode(LED_ETH_PIN, OUTPUT);
  digitalWrite(LED_ETH_PIN, LOW);
#endif

  // LoRa
  Serial2.begin(9600, SERIAL_8N1, 16, 17);
  Serial2.setTimeout(50);
  delay(200);
  lora.begin();

  // RTC
  Wire.begin();
  g_rtc_present = rtc.begin();
  if (g_rtc_present) {
    g_rtc_has_time = !rtc.lostPower();
    if (!g_rtc_has_time) {
      rtc.adjust(DateTime(__DATE__, __TIME__));
      g_rtc_has_time = true;
    }
  }

  // Ethernet
  (void)startEthernet();

  // TLS bind client chính
  ssl_client.setClient(&eth_client);
  ssl_client.setInsecure();           // Prod: thay bằng CA bundle
  ssl_client.setBufferSizes(4096, 1024);
  ssl_client.setDebugLevel(0);
  ssl_client.setHandshakeTimeout(15000);
  ssl_client.setTimeout(15000);

  // Firebase
  initializeApp(aClient, app, getAuth(userAuth),
                [](AsyncResult &r){
#if DEBUG
                  if (r.isEvent()) Serial.printf("[APP][event] %s\n", r.eventLog().message().c_str());
                  if (r.isError()) Serial.printf("[APP][error] %s (%d)\n", r.error().message().c_str(), r.error().code());
                  if (r.isDebug()) Serial.printf("[APP][debug] %s\n", r.debug().c_str());
#endif
                },
                "authTask");
  app.getApp<RealtimeDatabase>(Database);
  Database.url(DATABASE_URL);
  initSchedules();
  // ==== STREAM SETUP theo đúng ví dụ API ====
  auto setupSsl = [&](ESP_SSLClient& cli){
    cli.setClient(&eth_client);
    cli.setInsecure();              // Prod: dùng CA bundle để verify
    cli.setBufferSizes(4096, 1024);
    cli.setDebugLevel(0);
    cli.setHandshakeTimeout(15000);
    cli.setTimeout(15000);
  };
  setupSsl(ssl_stream_N01);
  setupSsl(ssl_stream_N02);

  ssl_stream_N01.setClient(&eth_s1);
  ssl_stream_N02.setClient(&eth_s2);

  ssl_stream_N01.setDebugLevel(0);
  ssl_stream_N02.setDebugLevel(0);

  // (Tuỳ chọn) lọc sự kiện SSE để tránh spam
  aStreamN01.setSSEFilters("put,patch,keep-alive,cancel,auth_revoked");
aStreamN02.setSSEFilters("put,patch,keep-alive,cancel,auth_revoked");

  
}

void loop() {
  app.loop(); // duy trì auth & stream

  static bool fb_ready_latched = false;
  if (!fb_ready_latched && app.ready()) {
    g_fb_ready = true;
    (void)syncRtcViaNTP();
    fb_ready_latched = true;
#if DEBUG
    Serial.println("[APP] ready -> g_fb_ready=1");
#endif
  }

if (app.ready()) {
    if (!g_stream_N01) {
      aStreamN01.setSSEFilters("get,put,patch,keep-alive,cancel,auth_revoked");
      Database.get(aStreamN01, String("/nodes/") + "N01" + "/downlink",
                   processDownlinkStream, true /* SSE */, "dl_N01");
      g_stream_N01 = true;
    }
    if (!g_stream_N02) {
      aStreamN02.setSSEFilters("get,put,patch,keep-alive,cancel,auth_revoked");
      Database.get(aStreamN02, String("/nodes/") + "N02" + "/downlink",
                   processDownlinkStream, true /* SSE */, "dl_N02");
      g_stream_N02 = true;
    }
  }

  // Uplink: Nhận từ LoRa -> parse -> đẩy Firebase
   // Uplink: Nhận từ LoRa -> parse -> đẩy Firebase
  if (!gatewayReady()) {
    while (lora.available() > 0) { (void)lora.receiveMessage(); }
  } else {
    if (lora.available() > 0) {
      ResponseContainer rc = lora.receiveMessage();
      if (rc.status.code == 1) {
        String data = rc.data; data.trim();
        if (data.length() > 4096) data = data.substring(0, 4096);
        handleUplinkPacket(data);
      }
    }
  }
  processCommandQueue();
  pollSchedulesFromFirebase();
  evaluateSchedules();
  // Re-init Ethernet nếu link down
  static uint32_t lastEthCheck = 0;
  if (millis() - lastEthCheck > 8000) {
    lastEthCheck = millis();
    if (Ethernet.linkStatus() == LinkOFF) {
#if DEBUG
      Serial.println("[ETH] Link OFF, re-init");
#endif
      (void)startEthernet();
    }
  }
   if (g_eth_ready && Ethernet.linkStatus() == LinkON) {
    const uint32_t BLINK_MS = 1000; // chu kỳ nháy 500ms
    if (millis() - g_led_tick >= BLINK_MS) {
      g_led_tick = millis();
      g_led_on = !g_led_on;
      digitalWrite(LED_ETH_PIN, g_led_on ? HIGH : LOW);
    }
  } else {
    // Chưa có Ethernet hoặc link OFF -> tắt LED và reset trạng thái nháy
    g_led_on = false;
    digitalWrite(LED_ETH_PIN, LOW);
  }
  delay(0);
}
