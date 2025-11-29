#include <Arduino.h>
#include <SoftwareSerial.h>
#include <LoRa_E32.h>
#include <DHT.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <BH1750.h>
#include "ScioSense_ENS160.h"

// ===== Cấu hình chung =====
#define NODE_ID          1
#define SEND_INTERVAL_MS 20000UL
#define MAX_E32_PAYLOAD  58

// ===== Cảm biến =====
#define DHTPIN  2
#define DHTTYPE DHT22
DHT dht(DHTPIN, DHTTYPE);

#define SOIL_PIN       A0
const int SOIL_DRY_ADC = 1022;   // hiệu chỉnh theo thực tế
const int SOIL_WET_ADC = 203;    // hiệu chỉnh theo thực tế

BH1750 lightMeter(0x23);         // I2C: A4 SDA, A5 SCL
ScioSense_ENS160 ens160(ENS160_I2CADDR_1);  // 0x53

// ===== LoRa E32 (AS32) =====
SoftwareSerial e32Serial(4, 5);  // RX, TX
LoRa_E32 lora(&e32Serial, 9600);

// ===== Thời gian =====
unsigned long lastSend = 0;

// ---- ENS210 format (Kelvin*64, %RH*512) ----
static inline uint16_t toENS210_T(float tC) { return (uint16_t)((tC + 273.15f) * 64.0f + 0.5f); }
static inline uint16_t toENS210_H(float rh) {
  if (rh < 0) rh = 0; if (rh > 100) rh = 100; return (uint16_t)(rh * 512.0f + 0.5f);
}

void setup() {
  Serial.begin(9600);

  e32Serial.begin(9600);
  e32Serial.setTimeout(50);

  Wire.begin();
  dht.begin();
  lightMeter.begin(BH1750::CONTINUOUS_HIGH_RES_MODE);

  if (!ens160.begin()) { Serial.println(F("[ENS160] FAIL @0x53")); while (1) delay(10); }
  ens160.setMode(ENS160_OPMODE_STD);
  ens160.set_envdata210(toENS210_T(25.0f), toENS210_H(50.0f)); // bù tạm

  if (!lora.begin()) Serial.println(F("[AS32] begin FAIL"));
  Serial.println(F("Node started."));
}

void loop() {
  const unsigned long now = millis();
  if (now - lastSend < SEND_INTERVAL_MS) return;
  lastSend = now;

  // ---- DHT22 (bù ENS160) ----
  float h = dht.readHumidity();
  float t = dht.readTemperature();
  const bool th_ok = (!isnan(h) && !isnan(t) && t > -40 && t < 85 && h >= 0 && h <= 100);
  if (th_ok) ens160.set_envdata210(toENS210_T(t), toENS210_H(h));

  // ---- ENS160 ----
  uint16_t tvoc = 0, eco2 = 0; uint8_t aqi = 0; bool ens_ok = false;
  if (ens160.measure(true)) { tvoc = ens160.getTVOC(); eco2 = ens160.geteCO2(); aqi = ens160.getAQI(); ens_ok = true; }

  // ---- Soil % ----
  const int soilRaw = analogRead(SOIL_PIN);
  float soilPct = 100.0f * (SOIL_DRY_ADC - soilRaw) / (float)(SOIL_DRY_ADC - SOIL_WET_ADC);
  if (soilPct < 0) soilPct = 0; if (soilPct > 100) soilPct = 100;

  // ---- Lux ----
  const float lux_f = lightMeter.readLightLevel();
  const int   lux   = (lux_f >= 0.0f && lux_f < 120000.0f) ? (int)(lux_f + 0.5f) : 0;

  // ---- Scale số nguyên để gọn payload ----
  const int t10 = th_ok ? (int)round(t * 10.0f) : 0;     // °C x10
  const int h10 = th_ok ? (int)round(h * 10.0f) : 0;     // %RH x10
  int s10 = (int)round(soilPct * 10.0f); if (s10 < 0) s10 = 0; if (s10 > 1000) s10 = 1000;
  const unsigned long ts5 = (now / 1000UL) % 100000UL;   // timestamp rút gọn

  // ---- JSON array ≤58B: [n,t10,h10,s10,lux,eco2,tvoc,aqi,ts5] ----
  StaticJsonDocument<64> doc;
  JsonArray arr = doc.to<JsonArray>();
  arr.add(NODE_ID);
  arr.add(t10);
  arr.add(h10);
  arr.add(s10);
  arr.add(lux);
  arr.add(ens_ok ? eco2 : 0);
  arr.add(ens_ok ? tvoc : 0);
  arr.add(ens_ok ? aqi  : 0);
  arr.add(ts5);

  String payload; serializeJson(arr, payload);

  Serial.print(F("[LEN] ")); Serial.print(payload.length()); Serial.print(F("B  [TX] ")); Serial.println(payload);
  if (payload.length() > MAX_E32_PAYLOAD) {
    Serial.println(F("[ERR][LEN] >58B -> skip"));
    return;
  }

  ResponseStatus rs = lora.sendFixedMessage(0x00, 0x00, 23, payload);  // sửa địa chỉ/kênh nếu cần
  if (rs.code == 1) Serial.println(F("[TX] OK"));
  else { Serial.print(F("[ERR][SEND] ")); Serial.println(rs.getResponseDescription()); }
}
