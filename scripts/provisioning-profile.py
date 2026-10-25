"""Read-only, in-memory verification of Apple-signed provisioning content."""

import base64
import ctypes as C
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess


def require(value, message):
    if not value:
        raise ValueError(message)


def read_private(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "Profile requires an absolute, unredirected path.")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=directory)
            os.close(directory)
            directory = child
            info = os.fstat(directory)
            require(info.st_uid in (0, os.getuid()) and not info.st_mode & 0o022,
                    "Profile ancestor ownership or permissions are unsafe.")
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_uid in (0, os.getuid())
                    and before.st_nlink == 1 and not before.st_mode & 0o022
                    and 0 < before.st_size <= 1_048_576, "Profile file is unsafe or oversized.")
            data = b""
            while len(data) <= 1_048_576:
                part = os.read(fd, min(65_536, 1_048_577 - len(data)))
                if not part:
                    break
                data += part
            after = os.fstat(fd)
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                    == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                    and len(data) == before.st_size, "Profile changed while reading.")
            return data
        finally:
            os.close(fd)
    finally:
        os.close(directory)


def decode_verified(data, runner=subprocess.run):
    """CMSDecoder verifies without importing certificates into the user's keychain."""
    security = C.CDLL("/System/Library/Frameworks/Security.framework/Security")
    cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    pointer = C.c_void_p
    out = C.POINTER(pointer)
    signatures = [
        (cf, "CFRelease", None, [pointer]),
        (cf, "CFDataCreate", pointer, [pointer, pointer, C.c_long]),
        (cf, "CFDataGetLength", C.c_long, [pointer]),
        (cf, "CFDataGetBytePtr", pointer, [pointer]),
        (cf, "CFArrayCreate", pointer, [pointer, pointer, C.c_long, pointer]),
        (cf, "CFStringGetCString", C.c_bool, [pointer, pointer, C.c_long, C.c_uint32]),
        (security, "SecCertificateCreateWithData", pointer, [pointer, pointer]),
        (security, "SecCertificateCopySubjectSummary", pointer, [pointer]),
        (security, "SecPolicyCreateBasicX509", pointer, []),
        (security, "CMSDecoderCreate", C.c_int32, [out]),
        (security, "CMSDecoderUpdateMessage", C.c_int32, [pointer, pointer, C.c_size_t]),
        (security, "CMSDecoderFinalizeMessage", C.c_int32, [pointer]),
        (security, "CMSDecoderGetNumSigners", C.c_int32, [pointer, C.POINTER(C.c_size_t)]),
        (security, "CMSDecoderCopySignerStatus", C.c_int32,
         [pointer, C.c_size_t, pointer, C.c_bool, C.POINTER(C.c_uint32), out, C.POINTER(C.c_int32)]),
        (security, "CMSDecoderCopySignerCert", C.c_int32, [pointer, C.c_size_t, out]),
        (security, "CMSDecoderCopyContent", C.c_int32, [pointer, out]),
        (security, "SecTrustSetAnchorCertificates", C.c_int32, [pointer, pointer]),
        (security, "SecTrustSetAnchorCertificatesOnly", C.c_int32, [pointer, C.c_bool]),
        (security, "SecTrustSetNetworkFetchAllowed", C.c_int32, [pointer, C.c_bool]),
        (security, "SecTrustEvaluateWithError", C.c_bool, [pointer, out]),
    ]
    for library, name, result, arguments in signatures:
        function = getattr(library, name)
        function.restype, function.argtypes = result, arguments
    retained = []

    def keep(value):
        require(value, "Provisioning cryptographic verification failed.")
        retained.append(value)
        return value

    def check(status):
        require(status == 0, "Provisioning cryptographic verification failed.")

    try:
        decoder = pointer()
        check(security.CMSDecoderCreate(C.byref(decoder)))
        keep(decoder)
        check(security.CMSDecoderUpdateMessage(decoder, data, len(data)))
        check(security.CMSDecoderFinalizeMessage(decoder))
        count = C.c_size_t()
        check(security.CMSDecoderGetNumSigners(decoder, C.byref(count)))
        require(count.value == 1, "Profile must have exactly one CMS signer.")
        policy = keep(security.SecPolicyCreateBasicX509())
        status, trust, result = C.c_uint32(), pointer(), C.c_int32()
        check(security.CMSDecoderCopySignerStatus(decoder, 0, policy, False,
                                                 C.byref(status), C.byref(trust), C.byref(result)))
        keep(trust)
        require(status.value == 1, "Profile CMS signature is invalid.")

        # Only immutable OS Apple roots, not user-added trust anchors.
        roots = runner(["/usr/bin/security", "find-certificate", "-a", "-c", "Apple Root CA", "-p",
                        "/System/Library/Keychains/SystemRootCertificates.keychain"],
                       check=True, capture_output=True, timeout=30).stdout
        anchors = []
        for pem in re.findall(rb"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", roots, re.S):
            der = base64.b64decode(pem)
            value = keep(cf.CFDataCreate(None, der, len(der)))
            anchors.append(keep(security.SecCertificateCreateWithData(None, value)))
        require(anchors, "System Apple trust anchors unavailable.")
        callbacks = C.addressof(C.c_byte.in_dll(cf, "kCFTypeArrayCallBacks"))
        array = keep(cf.CFArrayCreate(None, (pointer * len(anchors))(*anchors), len(anchors), callbacks))
        check(security.SecTrustSetAnchorCertificates(trust, array))
        check(security.SecTrustSetAnchorCertificatesOnly(trust, True))
        check(security.SecTrustSetNetworkFetchAllowed(trust, False))
        require(security.SecTrustEvaluateWithError(trust, None), "Profile signer is not trusted.")
        certificate = pointer()
        check(security.CMSDecoderCopySignerCert(decoder, 0, C.byref(certificate)))
        keep(certificate)
        subject = keep(security.SecCertificateCopySubjectSummary(certificate))
        text = C.create_string_buffer(512)
        require(cf.CFStringGetCString(subject, text, len(text), 0x08000100)
                and text.value == b"Mac OS X Provisioning Profile Signing",
                "CMS signer is not the Apple provisioning authority.")
        content = pointer()
        check(security.CMSDecoderCopyContent(decoder, C.byref(content)))
        keep(content)
        length = cf.CFDataGetLength(content)
        require(0 < length <= 1_048_576, "Profile content is oversized.")
        return plistlib.loads(C.string_at(cf.CFDataGetBytePtr(content), length))
    finally:
        for value in reversed(retained):
            cf.CFRelease(value)
