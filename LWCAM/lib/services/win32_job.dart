// ignore_for_file: avoid_print

// Windows FFI wrapper around a Job Object with kill-on-close. The capture app
// (LWCAM) uses it so the scrcpy phone-mirror child process dies with the app,
// even on a crash. The struct layouts below are hand-written because
// package:win32 does not expose them; they assume the x64 ABI.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// A Windows Job Object with kill-on-close, used to guarantee a spawned child
/// process (scrcpy's mirror) can never outlive LWCAM: when the held job handle
/// closes — including on an app crash — the OS terminates every process in
/// the job. Extracted from ScrcpyService so any future supervisor can share
/// this implementation instead of reinventing it.

// ── Job-object structs (not exposed by package:win32) ───────────────────────
// Layouts match the Windows x64 ABI; only limitFlags is actually written.

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;
  external _IoCounters ioCounters;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

/// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE — terminate all job processes when the
/// last job handle closes (i.e. when this app exits, however it exits).
const int _jobLimitKillOnJobClose = 0x2000;
const int _jobObjectExtendedLimitInformation = 9;

/// Creates a kill-on-close job object and assigns [processPid] to it. Returns
/// the job handle to hold for the process's intended lifetime (closing it
/// terminates the process), or 0 on any failure. Never throws.
int assignToKillOnCloseJob(int processPid) {
  try {
    final hJob = CreateJobObject(nullptr, nullptr);
    if (hJob == 0) return 0;
    final info = calloc<_JobObjectExtendedLimitInformation>();
    try {
      info.ref.basicLimitInformation.limitFlags = _jobLimitKillOnJobClose;
      final ok = SetInformationJobObject(
        hJob,
        _jobObjectExtendedLimitInformation,
        info.cast(),
        sizeOf<_JobObjectExtendedLimitInformation>(),
      );
      if (ok == 0) {
        CloseHandle(hJob);
        return 0;
      }
    } finally {
      calloc.free(info);
    }
    final hProc = OpenProcess(
      PROCESS_SET_QUOTA | PROCESS_TERMINATE,
      FALSE,
      processPid,
    );
    if (hProc == 0) {
      CloseHandle(hJob);
      return 0;
    }
    final assigned = AssignProcessToJobObject(hJob, hProc);
    CloseHandle(hProc);
    if (assigned == 0) {
      CloseHandle(hJob);
      return 0;
    }
    return hJob;
  } catch (e) {
    print('⚠️ Job-object setup failed (child may outlive a crash): $e');
    return 0;
  }
}

/// Closes a job handle from [assignToKillOnCloseJob] — kill-on-close means
/// this also terminates the assigned process. Safe to call with 0.
void closeJobHandle(int handle) {
  if (handle == 0) return;
  try {
    CloseHandle(handle);
  } catch (_) {}
}
