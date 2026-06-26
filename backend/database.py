import os
from datetime import datetime, date
from sqlalchemy import (
    create_engine, Column, Integer, String, Float, Boolean, DateTime, Date, ForeignKey, JSON, Numeric, Index
)
from sqlalchemy.orm import declarative_base, sessionmaker, relationship
from sqlalchemy.sql import text

# Load .env file manually
def load_env():
    for path in [".env", "../.env", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")]:
        if os.path.exists(path):
            with open(path, "r") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        key, val = line.split("=", 1)
                        os.environ[key.strip()] = val.strip()
            break

load_env()

# Database connection details
DATABASE_URL = os.getenv("DATABASE_URL")
DB_NAME = "bloodsense"

if DATABASE_URL:
    try:
        DB_NAME = DATABASE_URL.split("/")[-1].split("?")[0]
    except Exception:
        pass
    print("Using direct DATABASE_URL connection.")
else:
    DB_USER = os.getenv("DB_USER", "postgres")
    DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")
    DB_HOST = os.getenv("DB_HOST", "localhost")
    DB_PORT = os.getenv("DB_PORT", "5432")
    DB_NAME = os.getenv("DB_NAME", "bloodsense")
    
    DATABASE_URL = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    DEFAULT_DB_URL = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/postgres"

    # Function to ensure target database exists
    def ensure_database_exists():
        # Connect to the default 'postgres' database to check and create 'bloodsense'
        temp_engine = create_engine(DEFAULT_DB_URL, isolation_level="AUTOCOMMIT")
        try:
            with temp_engine.connect() as conn:
                # Check if db exists using parameterized queries
                result = conn.execute(
                    text("SELECT 1 FROM pg_database WHERE datname = :dbname"),
                    {"dbname": DB_NAME}
                )
                exists = result.scalar()
                if not exists:
                    # DDL identifiers cannot be parameterized, so we quote the database name to harden the query
                    safe_db_name = DB_NAME.replace('"', '""')
                    conn.execute(text(f'CREATE DATABASE "{safe_db_name}"'))
                    print(f"Database '{DB_NAME}' successfully created.")
                else:
                    print(f"Database '{DB_NAME}' already exists.")
        except Exception as e:
            print(f"Warning: Could not check/create database '{DB_NAME}' automatically. Error: {e}")
        finally:
            temp_engine.dispose()

    # Run database verification
    ensure_database_exists()

# Initialize Engine and Session
engine = create_engine(DATABASE_URL, pool_size=10, max_overflow=20)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# Models Definition
class Region(Base):
    __tablename__ = "regions"
    
    region_id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    state = Column(String(100), nullable=False)
    district = Column(String(100), nullable=False)
    accident_risk_level = Column(Integer, default=1)  # 1 to 5

    banks = relationship("BloodBank", back_populates="region")
    hospitals = relationship("Hospital", back_populates="region")
    emergency_events = relationship("EmergencyEvent", back_populates="region")


class BloodBank(Base):
    __tablename__ = "blood_banks"
    
    bank_id = Column(Integer, primary_key=True, index=True)
    name = Column(String(200), nullable=False)
    location_lat = Column(Float, nullable=False)
    location_lng = Column(Float, nullable=False)
    region_id = Column(Integer, ForeignKey("regions.region_id"), nullable=False)
    contact_phone = Column(String(20), nullable=False)
    admin_user_id = Column(String(128), nullable=True)  # Firebase UID of admin
    address = Column(String(500), nullable=True)
    password_hash = Column(String(255), nullable=True)
    establishment_date = Column(Date, nullable=True)
    website_link = Column(String(255), nullable=True)
    approval_document_base64 = Column(String, nullable=True)
    approval_document_name = Column(String(255), nullable=True)
    is_approved = Column(Boolean, default=False)

    region = relationship("Region", back_populates="banks")
    inventory = relationship("BloodInventory", back_populates="bank")
    donation_records = relationship("DonationRecord", back_populates="bank")
    bssi_scores = relationship("BSSIScore", back_populates="bank")
    alerts = relationship("ShortageAlert", back_populates="bank")
    
    # Redistribution suggestions (requesting vs supplying)
    redistributions_requested = relationship(
        "Redistribution", foreign_keys="Redistribution.requesting_bank_id", back_populates="requesting_bank"
    )
    redistributions_supplied = relationship(
        "Redistribution", foreign_keys="Redistribution.supplying_bank_id", back_populates="supplying_bank"
    )


class Hospital(Base):
    __tablename__ = "hospitals"
    
    hospital_id = Column(Integer, primary_key=True, index=True)
    name = Column(String(200), nullable=False)
    location_lat = Column(Float, nullable=False)
    location_lng = Column(Float, nullable=False)
    region_id = Column(Integer, ForeignKey("regions.region_id"), nullable=False)
    avg_daily_consumption = Column(JSON, nullable=False)  # Map: blood_group -> avg_units
    address = Column(String(500), nullable=True)

    region = relationship("Region", back_populates="hospitals")
    transfusions = relationship("TransfusionRecord", back_populates="hospital")


class Donor(Base):
    __tablename__ = "donors"
    __table_args__ = (
        Index('idx_donors_location', 'location_lat', 'location_lng'),
    )
    
    donor_id = Column(Integer, primary_key=True, index=True)
    firebase_uid = Column(String(128), unique=True, index=True, nullable=False)
    name = Column(String(150), nullable=False)
    phone = Column(String(20), nullable=False)
    blood_group = Column(String(5), nullable=False)
    dob = Column(Date, nullable=False)
    location_lat = Column(Float, nullable=False)
    location_lng = Column(Float, nullable=False)
    last_donation_date = Column(Date, nullable=True)
    is_eligible = Column(Boolean, default=True)
    fcm_token = Column(String(255), nullable=True)
    response_count = Column(Integer, default=0)
    alert_count = Column(Integer, default=0)
    response_rate = Column(Float, default=0.0)  # response_count / alert_count
    registered_at = Column(DateTime, default=datetime.utcnow)
    password_hash = Column(String(255), nullable=True)
    id_document_base64 = Column(String, nullable=True)
    id_document_name = Column(String(255), nullable=True)
    consent_given = Column(Boolean, default=False, nullable=False)

    donations = relationship("DonationRecord", back_populates="donor")
    alert_logs = relationship("DonorAlertLog", back_populates="donor")


class DonationRecord(Base):
    __tablename__ = "donation_records"
    
    record_id = Column(Integer, primary_key=True, index=True)
    donor_id = Column(Integer, ForeignKey("donors.donor_id"), nullable=True)
    bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    units = Column(Float, nullable=False)
    donated_at = Column(Date, nullable=False)
    is_festival_day = Column(Boolean, default=False)
    accident_count_that_day = Column(Integer, default=0)
    season = Column(String(20), nullable=False)  # "Summer", "Winter", "Monsoon", etc.

    donor = relationship("Donor", back_populates="donations")
    bank = relationship("BloodBank", back_populates="donation_records")


class TransfusionRecord(Base):
    __tablename__ = "transfusion_records"
    
    record_id = Column(Integer, primary_key=True, index=True)
    hospital_id = Column(Integer, ForeignKey("hospitals.hospital_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    units = Column(Float, nullable=False)
    transfused_at = Column(Date, nullable=False)
    emergency_flag = Column(Boolean, default=False)

    hospital = relationship("Hospital", back_populates="transfusions")


class BloodInventory(Base):
    __tablename__ = "blood_inventory"
    
    inventory_id = Column(Integer, primary_key=True, index=True)
    bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    units_available = Column(Float, default=0.0)
    units_expiring_3days = Column(Float, default=0.0)
    last_updated = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    bank = relationship("BloodBank", back_populates="inventory")


class BSSIScore(Base):
    __tablename__ = "bssi_scores"
    
    score_id = Column(Integer, primary_key=True, index=True)
    bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    score = Column(Numeric(5, 2), nullable=False)
    inventory_gap_score = Column(Numeric(5, 4), nullable=False)
    donation_trend_score = Column(Numeric(5, 4), nullable=False)
    accident_signal_score = Column(Numeric(5, 4), nullable=False)
    rare_group_flag = Column(Numeric(5, 4), nullable=False)
    expiry_pressure_score = Column(Numeric(5, 4), nullable=False)
    computed_at = Column(DateTime, default=datetime.utcnow)

    # Lineage tracking foreign keys
    forecast_cache_id = Column(Integer, ForeignKey("forecast_cache.cache_id"), nullable=True)
    blood_inventory_id = Column(Integer, ForeignKey("blood_inventory.inventory_id"), nullable=True)

    bank = relationship("BloodBank", back_populates="bssi_scores")
    forecast_cache = relationship("ForecastCache")
    blood_inventory = relationship("BloodInventory")


class ShortageAlert(Base):
    __tablename__ = "shortage_alerts"
    
    alert_id = Column(Integer, primary_key=True, index=True)
    bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    bssi_at_trigger = Column(Float, nullable=False)
    donors_notified = Column(Integer, default=0)
    donors_responded = Column(Integer, default=0)
    response_rate = Column(Float, default=0.0)
    triggered_at = Column(DateTime, default=datetime.utcnow)

    bank = relationship("BloodBank", back_populates="alerts")
    logs = relationship("DonorAlertLog", back_populates="alert")


class DonorAlertLog(Base):
    __tablename__ = "donor_alert_log"
    
    log_id = Column(Integer, primary_key=True, index=True)
    alert_id = Column(Integer, ForeignKey("shortage_alerts.alert_id"), nullable=False)
    donor_id = Column(Integer, ForeignKey("donors.donor_id"), nullable=False)
    notified_at = Column(DateTime, default=datetime.utcnow)
    response = Column(String(20), default="no_response")  # "accepted", "declined", "no_response"
    responded_at = Column(DateTime, nullable=True)

    alert = relationship("ShortageAlert", back_populates="logs")
    donor = relationship("Donor", back_populates="alert_logs")


class Redistribution(Base):
    __tablename__ = "redistribution"
    
    suggestion_id = Column(Integer, primary_key=True, index=True)
    requesting_bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    supplying_bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    suggested_units = Column(Float, nullable=False)
    status = Column(String(20), default="pending")  # "pending", "accepted", "completed"
    created_at = Column(DateTime, default=datetime.utcnow)

    requesting_bank = relationship("BloodBank", foreign_keys=[requesting_bank_id], back_populates="redistributions_requested")
    supplying_bank = relationship("BloodBank", foreign_keys=[supplying_bank_id], back_populates="redistributions_supplied")


class EmergencyEvent(Base):
    __tablename__ = "emergency_events"
    
    event_id = Column(Integer, primary_key=True, index=True)
    region_id = Column(Integer, ForeignKey("regions.region_id"), nullable=False)
    event_type = Column(String(100), nullable=False)
    severity = Column(Integer, default=1)  # 1 to 5
    event_date = Column(Date, nullable=False)
    estimated_blood_impact_units = Column(Float, nullable=False)

    region = relationship("Region", back_populates="emergency_events")


class CalendarFlags(Base):
    __tablename__ = "calendar_flags"
    
    flag_id = Column(Integer, primary_key=True, index=True)
    date = Column(Date, unique=True, index=True, nullable=False)
    is_festival = Column(Boolean, default=False)
    is_holiday = Column(Boolean, default=False)
    festival_name = Column(String(100), nullable=True)
    expected_donation_impact = Column(Float, default=0.0)  # negative float representing drop %


class ForecastCache(Base):
    __tablename__ = "forecast_cache"
    
    cache_id = Column(Integer, primary_key=True, index=True)
    bank_id = Column(Integer, ForeignKey("blood_banks.bank_id"), nullable=False)
    blood_group = Column(String(5), nullable=False)
    forecast_date = Column(Date, nullable=False)
    yhat = Column(Float, nullable=False)
    yhat_lower = Column(Float, nullable=False)
    yhat_upper = Column(Float, nullable=False)
    generated_at = Column(DateTime, default=datetime.utcnow)


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    
    id = Column(Integer, primary_key=True, index=True)
    donor_id = Column(Integer, ForeignKey("donors.donor_id"), nullable=True)
    token_hash = Column(String(255), unique=True, index=True, nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)
    revoked = Column(Boolean, default=False, nullable=False)


class ModelPerformance(Base):
    __tablename__ = "model_performance"
    
    performance_id = Column(Integer, primary_key=True, index=True)
    region = Column(String(100), nullable=False)
    blood_group = Column(String(5), nullable=False)
    method = Column(String(50), nullable=False)  # "Prophet", "SARIMA", "Rolling Average"
    mape = Column(Float, nullable=False)
    rmse = Column(Float, nullable=False)
    trained_at = Column(DateTime(timezone=True), default=datetime.utcnow)


class SystemMetadata(Base):
    __tablename__ = "system_metadata"
    
    key = Column(String(100), primary_key=True)
    value = Column(String(255), nullable=False)


class DonorBehaviorReference(Base):
    __tablename__ = "donor_behavior_reference"
    
    id = Column(Integer, primary_key=True, index=True)
    recency_months = Column(Integer, nullable=False)
    frequency_times = Column(Integer, nullable=False)
    monetary_cc = Column(Integer, nullable=False)
    time_months = Column(Integer, nullable=False)
    donated_march_2007 = Column(Integer, nullable=False)


class RealAccidentReference(Base):
    __tablename__ = "real_accident_reference"
    
    id = Column(Integer, primary_key=True, index=True)
    state = Column(String(100), nullable=False)
    total_accidents = Column(Integer, nullable=False)
    killed = Column(Integer, nullable=False)
    injured = Column(Integer, nullable=False)
    year = Column(Integer, nullable=False)


class DataProvenance(Base):
    __tablename__ = "data_provenance"
    
    id = Column(Integer, primary_key=True, index=True)
    field_name = Column(String(100), nullable=False)
    tier = Column(Integer, nullable=False)  # 1, 2, 3
    source_dataset = Column(String(200), nullable=False)
    access_date = Column(DateTime(timezone=True), default=datetime.utcnow)
    methodology = Column(String(500), nullable=False)


def init_db():
    Base.metadata.create_all(bind=engine)
    print("Database tables initialized successfully.")

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
