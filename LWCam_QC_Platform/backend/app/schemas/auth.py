from pydantic import BaseModel, Field, field_validator


class LoginRequest(BaseModel):
    # Bounded to match users.user_id (String(255)) and CreateUserRequest, which
    # were already capped. A username longer than the column can hold cannot
    # identify an account, so accepting one only ever gave the rate limiter a
    # larger key to remember.
    username: str = Field(min_length=1, max_length=255)
    password: str = Field(min_length=1, max_length=1024)

    @field_validator("username")
    @classmethod
    def trim_username(cls, value: str) -> str:
        return value.strip()


class ChangePasswordRequest(BaseModel):
    oldPassword: str = Field(min_length=1)
    newPassword: str = Field(min_length=6, max_length=64)


class UserVO(BaseModel):
    id: int
    userId: str
    role: str
    # Every role held. `role` is the display/landing one; route guards must use
    # this, or a 'qc,admin' account loses access to the QC views.
    roles: list[str] = []
    status: str
    homePath: str
    mustChangePassword: bool


class AuthResponse(BaseModel):
    token: str
    user: UserVO
