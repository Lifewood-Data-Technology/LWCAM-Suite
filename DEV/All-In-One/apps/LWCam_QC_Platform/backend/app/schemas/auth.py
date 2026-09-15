from pydantic import BaseModel, Field, field_validator


class LoginRequest(BaseModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)

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
