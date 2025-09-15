import os, json, hashlib, sys
from datetime import datetime, timezone
import requests
#aws sdk for python
import boto3
from botocore.config import Config

# Config (replace with your values)
API_KEY = "***********************"   # <--- put your WeatherAPI key here
LOCATION = "Austin"
AWS_REGION = "us-east-1"
STREAM_NAME = "weather-ingest-stream"
#starts session which aws region to use 
session = boto3.session.Session(region_name=AWS_REGION)
#creates kinesis stream object
kinesis = session.client("kinesis", config=Config(retries={"max_attempts": 5, "mode": "adaptive"}))
#weather api base url
BASE_URL = "https://api.weatherapi.com/v1"

def fetch_weather():
    url = f"{BASE_URL}/current.json?key={API_KEY}&q={LOCATION}&aqi=no"
    r = requests.get(url, timeout=10)
    r.raise_for_status()
    return r.json()

def normalize_weather(payload):
    now_utc = datetime.now(timezone.utc).isoformat()
    loc = payload["location"]
    cur = payload["current"]

    record = {
        "schema_version": 1,
        "event_type": "weather.current",
        "ingest_ts": now_utc,
        "location": loc.get("name"),
        "region": loc.get("region"),
        "country": loc.get("country"),
        "lat": loc.get("lat"),
        "lon": loc.get("lon"),
        "temp_c": cur.get("temp_c"),
        "humidity": cur.get("humidity"),
        "wind_kph": cur.get("wind_kph"),
        "condition": (cur.get("condition") or {}).get("text"),
    }
    return record

def send_to_kinesis(record):
    data = json.dumps(record).encode("utf-8")
    pk = hashlib.sha1(record["location"].encode()).hexdigest()
    kinesis.put_record(StreamName=STREAM_NAME, Data=data, PartitionKey=pk)
    print(f" Sent weather record for {record['location']}")

def main():
    try:
        payload = fetch_weather()
        record = normalize_weather(payload)
        send_to_kinesis(record)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()
