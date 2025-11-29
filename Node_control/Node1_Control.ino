#include <Arduino.h>
#include <LoRa_E32.h>
#include <ArduinoJson.h>

// ----------- cấu hình UART LoRa E32 ----------
#define LORA_BAUD      9600
#define LORA_RX_PIN    16        // ESP32 UART2 RX
#define LORA_TX_PIN    17        // ESP32 UART2 TX
#define LORA_AUX_PIN    4
LoRa_E32 lora(&Serial2, LORA_BAUD);

// ----------- map relay ----------
#define PIN_RELAY_PUMP    25
#define PIN_RELAY_LIGHT   26
#define PIN_RELAY_FAN     27

// Relay module thường ACTIVE LOW (IN=0 -> ON, IN=1 -> OFF)
#define ACTIVE_LOW        false

// ----------- trạng thái thiết bị ----------
int stPump  = 0;
int stLight = 0;
int stFan   = 0;

// Chuyển ON/OFF sang mức chân phù hợp ACTIVE_LOW
inline int toLevel(int on) {
  if (ACTIVE_LOW) return on ? LOW : HIGH;
  return on ? HIGH : LOW;
}

// Đổi tên thiết bị -> con trỏ biến trạng thái
int* stateRefByName(const String& devName) {
  if (devName.equalsIgnoreCase("pump"))  return &stPump;
  if (devName.equalsIgnoreCase("light")) return &stLight;
  if (devName.equalsIgnoreCase("fan"))   return &stFan;
  return nullptr;
}

// Đổi tên thiết bị -> chân GPIO
int pinByName(const String& devName) {
  if (devName.equalsIgnoreCase("pump"))  return PIN_RELAY_PUMP;
  if (devName.equalsIgnoreCase("light")) return PIN_RELAY_LIGHT;
  if (devName.equalsIgnoreCase("fan"))   return PIN_RELAY_FAN;
  return -1;
}

// Áp lệnh cho 1 thiết bị
bool applyDevice(const String& devName, int value) {
  int* pState = stateRefByName(devName);
  int pin     = pinByName(devName);
  if (!pState || pin < 0) return false;
  value = (value != 0) ? 1 : 0;

  *pState = value;
  digitalWrite(pin, toLevel(value));
  return true;
}

// Gửi ACK về Gateway, kèm theo cmdId + device + value
void sendAck(const char* cmdId, const char* dev, int value) {
  StaticJsonDocument<96> doc;
  doc["ok"] = true;
  if (cmdId && cmdId[0]) doc["id"] = cmdId;
  if (dev   && dev[0])   doc["device"] = dev;
  doc["value"] = value ? 1 : 0;

  String payload;
  serializeJson(doc, payload);
  lora.sendMessage(payload);   // Transparent mode: gateway bắt ACK
}



// (Tuỳ chọn) Gửi log trạng thái hiện tại
void sendStatusLog(const char* note = nullptr) {
  StaticJsonDocument<160> d;
  d["pump"]  = stPump;
  d["light"] = stLight;
  d["fan"]   = stFan;
  if (note) d["note"] = note;
  String s; serializeJson(d, s);
  lora.sendMessage(s);
}

// Xử lý 1 lệnh set đơn lẻ
bool handleSetOne(const char* dev, int value) {
  if (!dev || value < 0) return false;
  String devName = String(dev);
  bool ok = applyDevice(devName, value);
  if (ok) {
    Serial.printf("[NODE][APPLY] %s = %s\n", devName.c_str(), value ? "ON" : "OFF");
  } else {
    Serial.printf("[NODE][ERROR] Unknown device: %s\n", devName.c_str());
  }
  return ok;
}


void handleIncoming(const String& raw) {
  String s = raw; 
  s.trim();
  if (!s.length()) return;

  if (s[0] != '{') return;

  StaticJsonDocument<512> doc;
  DeserializationError err = deserializeJson(doc, s);
  if (err) return;

  const char* cmd = doc["cmd"] | "";
  if (!cmd || !*cmd) return;

  // CHỈ XỬ LÝ LỆNH ĐƠN "set"
  if (strcmp(cmd, "set") == 0) {
    const char* dev   = doc["device"] | "";
    int         value = doc["value"] | -1;
    const char* cmdId = doc["id"]     | "";   // id lệnh để ACK cho gateway

    if (handleSetOne(dev, value)) {
      sendAck(cmdId, dev, value);   // ACK có thông tin để gateway đánh dấu done
    }
    return;
  }


  // Nếu vẫn muốn an toàn, có thể log các cmd khác để debug:
  Serial.printf("[NODE] Unknown cmd: %s\n", cmd);
}

// ===================== SETUP / LOOP =====================
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n[BOOT] Node dieu khien 01 ");

  // UART2 cho LoRa E32
  Serial2.begin(LORA_BAUD, SERIAL_8N1, LORA_RX_PIN, LORA_TX_PIN);
  Serial2.setTimeout(50);

  // Nếu không dùng AUX, kéo lên để tránh nhiễu mức (tuỳ phần cứng)
  pinMode(LORA_AUX_PIN, INPUT_PULLUP);

  delay(200);
  lora.begin();

  // Relay outputs
  pinMode(PIN_RELAY_PUMP,  OUTPUT);
  pinMode(PIN_RELAY_LIGHT, OUTPUT);
  pinMode(PIN_RELAY_FAN,   OUTPUT);

  // Mặc định tắt hết
  digitalWrite(PIN_RELAY_PUMP,  toLevel(0));
  digitalWrite(PIN_RELAY_LIGHT, toLevel(0));
  digitalWrite(PIN_RELAY_FAN,   toLevel(0));

  Serial.println("[NODE] Ready.");
}

void loop() {
  // Nhận lệnh từ Gateway
  if (lora.available() > 0) {
    ResponseContainer rc = lora.receiveMessage();
    if (rc.status.code == 1) {
      String data = rc.data;
      data.trim();
      if (data.length()) {
        Serial.print("[NODE][RX] "); Serial.println(data);
        handleIncoming(data);
      }
    } else {
      // Lỗi mức link/CRC...
      Serial.printf("[NODE][RX_ERR] code=%d\n", rc.status.code);
    }
  }

  // (Tuỳ chọn) Cho phép gửi tay lệnh bằng Serial để test
  if (Serial.available()) {
    String line = Serial.readStringUntil('\n');
    line.trim();
    if (line.length()) {
      Serial.print("[SERIAL->E32] "); Serial.println(line);
      lora.sendMessage(line);
    }
  }

  delay(5);
}
