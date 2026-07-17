from typing import Annotated
from uuid import UUID

from pydantic import AfterValidator, BaseModel, Field, model_validator

from app.core.phone import normalize_phone

# Identity phones are normalized to the canonical local format (09.../07...)
# at the schema boundary so lookups and uniqueness checks always compare the
# same representation. InvalidPhoneError subclasses ValueError → 422.
Phone = Annotated[str, AfterValidator(normalize_phone)]


class RegisterShopRequest(BaseModel):
    shop_name: str = Field(min_length=1, max_length=120)
    owner_name: str = Field(min_length=1, max_length=120)
    phone: Phone
    password: str = Field(min_length=8)
    owner_pin: str = Field(min_length=4, max_length=8, pattern=r"^\d+$")
    device_fingerprint: str
    device_label: str | None = None
    locale: str = "en"
    shop_type: str = "regular"

    @model_validator(mode="after")
    def _pin_not_password(self) -> "RegisterShopRequest":
        if self.owner_pin == self.password or self.owner_pin in self.password:
            raise ValueError("owner_pin must not match or be contained in password")
        if self.shop_type not in {"regular", "bakery"}:
            raise ValueError("shop_type must be 'regular' or 'bakery'")
        return self


class LoginRequest(BaseModel):
    phone: Phone
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
    shop_type: str = "regular"
    shop_name: str = ""
    # Shop-configurable thresholds, mirrored to the client at login/refresh
    # so offline checks use the shop's actual values, not hardcoded defaults.
    debt_threshold: str = "500.00"
    expense_approval_threshold: str = "500.00"


class InviteRequest(BaseModel):
    name: str
    phone: Phone
    role: str = "cashier"


class InviteResponse(BaseModel):
    invite_code: str
    expires_at: str


class AcceptInviteRequest(BaseModel):
    invite_code: str
    phone: Phone
    password: str = Field(min_length=8)
    device_fingerprint: str
    device_label: str | None = None


class OwnerPinVerifyRequest(BaseModel):
    pin: str


class ShopUser(BaseModel):
    id: UUID
    name: str
    phone: str
    role: str
    is_active: bool
    created_at: str


class ShopUsersResponse(BaseModel):
    users: list[ShopUser]
