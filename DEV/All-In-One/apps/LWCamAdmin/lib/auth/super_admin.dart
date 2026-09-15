/// The built-in recovery admin account, compiled into the exe so it works
/// even when PostgreSQL is unreachable and the local JSON snapshot is
/// missing or deleted. Only its bcrypt hash is embedded — the plaintext
/// factory password is not stored anywhere in source control or the binary.
///
/// Byte-identical to LWCAM's former copy of this file (see CHANGELOG:
/// SuperAdmin login moved here when the two apps split) — the hash was
/// generated once and is not derivable from anything in either repo.
///
/// This is the ONLY account LWCam Admin's login screen accepts.
library;

const String kSuperAdminUsername = 'SuperAdmin';

/// bcrypt hash of the factory password. Verified with [PasswordHasher.verify]
/// exactly like a stored user's passwordHash.
const String kSuperAdminFactoryHash =
    r'$2a$10$3H1G.opGzYmscGsV4pM0V.CrmTyjzSNMy/LOvXpJMEOHn0nn5NHQW';

/// Case/whitespace-insensitive match against the reserved SuperAdmin name.
bool isSuperAdminName(String username) =>
    username.trim().toLowerCase() == kSuperAdminUsername.toLowerCase();
