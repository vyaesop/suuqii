from uuid import UUID

from pydantic import BaseModel, Field


class RegisterShopRequest(BaseModel):
    shop_name: str = Field(min_length=1, max_length=120)
    owner_name: str = Field(min_length=1, max_length=120)
    phone: str
    password: str = Field(min_length=8)
    owner_pin: str = Field(min_length=4, max_length=8)
    locale: str = "en"


class LoginRequest(BaseModel):
    phone: str
    password: str
    device_fingerprint: str
    device_label: str | None = None


class RefreshRequest(BaseModel):
    refresh: str
    device_fingerprint: str


class TokenBundle(BaseModel):
    access: str
    refresh: str
    user_id: UUID
    shop_id: UUID
    role: str


class InviteRequest(BaseModel):
    name: str
    phone: str
    role: str = "cashier"


class InviteResponse(BaseModel):
    invite_code: str
    expires_at: str


class AcceptInviteRequest(BaseModel):
    invite_code: str
    phone: str
    password: str = Field(min_length=8)
    device_fingerprint: str
    device_label: str | None = None


class OwnerPinVerifyRequest(BaseModel):
    pin: str
