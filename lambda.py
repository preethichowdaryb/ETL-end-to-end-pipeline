# Runtime: Python 3.11
import os, json, base64, gzip, io, uuid
from datetime import datetime, timezone
from typing import Dict, Any, List
import boto3

s3 = boto3.client("s3")

# Where the robot puts the tidy bags
OUTPUT_BUCKET = os.getenv("OUTPUT_BUCKET", "transformedweatherapi")
OUTPUT_PREFIX = os.getenv("OUTPUT_PREFIX", "curated/weather/")

def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def _pick_fields(obj: Dict[str, Any]) -> Dict[str, Any]:
    """
    Keep only simple, easy toys (fields). Add a robot time sticker.
    """
    return {
        "schema_version": obj.get("schema_version", 1),
        "event_type":     obj.get("event_type", "weather.current"),
        "ingest_ts":      obj.get("ingest_ts"),   # from producer (may be None)
        "lambda_ts":      _utc_now_iso(),         # robot time (UTC)
        "location":       obj.get("location"),
        "region":         obj.get("region"),
        "country":        obj.get("country"),
        "lat":            obj.get("lat"),
        "lon":            obj.get("lon"),
        "temp_c":         obj.get("temp_c"),
        "humidity":       obj.get("humidity"),
        "wind_kph":       obj.get("wind_kph"),
        "condition":      obj.get("condition"),
    }

def _choose_partition_time(row: Dict[str, Any]) -> datetime:
    """
    Use producer's time if present (ingest_ts). If missing, use robot time (now).
    """
    ts = row.get("ingest_ts")
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except Exception:
            pass
    return datetime.now(timezone.utc)

def _partition_prefix(ts: datetime) -> str:
    # Shelves: dt=YYYY/MM/DD/HH/
    return f"dt={ts:%Y/%m/%d/%H}/"

def lambda_handler(event, context):
    """
    1) Open boxes from Kinesis (decode + json)
    2) Pick simple toys (fields)
    3) Add robot time sticker
    4) Put many toys into one bag (gzip JSON Lines)
    5) Place bag on the date shelf in S3
    """
    cleaned: List[Dict[str, Any]] = []
    first_time: datetime | None = None

    for rec in event.get("Records", []):
        data_b64 = rec.get("kinesis", {}).get("data")
        if not data_b64:
            continue
        try:
            raw = base64.b64decode(data_b64)   # open the box
            obj = json.loads(raw)              # read the toy list
        except Exception as e:
            print(f"[WARN] skipping bad record: {e}")
            continue

        row = _pick_fields(obj)                # keep only simple toys
        part_time = _choose_partition_time(row)
        if first_time is None:
            first_time = part_time
        cleaned.append(row)

    if not cleaned:
        print("[INFO] no valid records to write")
        return {"written": 0}

    # Build the shelf path (date/hour) and bag name
    ts = first_time or datetime.now(timezone.utc)
    key = f"{OUTPUT_PREFIX}{_partition_prefix(ts)}part-{uuid.uuid4().hex[:12]}.json.gz"

    # Put all toys into one bag (one JSON per line), then zip it small
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
        for row in cleaned:
            gz.write((json.dumps(row) + "\n").encode("utf-8"))

    s3.put_object(
        Bucket=OUTPUT_BUCKET,
        Key=key,
        Body=buf.getvalue(),
        ContentType="application/json",
        ContentEncoding="gzip"
    )
    print(f"[OK] wrote {len(cleaned)} records to s3://{OUTPUT_BUCKET}/{key}")
    return {"written": len(cleaned), "s3_key": key}