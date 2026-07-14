import {
  EvidenceValidationError,
  assertSafeRelativePath,
} from "./canonical-json.mjs";

const BLOCK_SIZE = 512;
const MIB = 1024 * 1024;
const USTAR_MAGIC = Buffer.from("ustar\0", "ascii");
const USTAR_VERSION = Buffer.from("00", "ascii");
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export const DEFAULT_TAR_LIMITS = Object.freeze({
  maxEntries: 10_000,
  maxEntryBytes: 128 * MIB,
  maxTotalBytes: 512 * MIB,
  maxArchiveBytes: 512 * MIB,
});

const CONTENT_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".jpeg", "image/jpeg"],
  [".jpg", "image/jpeg"],
  [".json", "application/json"],
  [".jsonl", "application/x-ndjson"],
  [".log", "text/plain; charset=utf-8"],
  [".mp4", "video/mp4"],
  [".png", "image/png"],
  [".txt", "text/plain; charset=utf-8"],
  [".webm", "video/webm"],
  [".xml", "application/xml"],
]);

function tarError(code, message, path = "archive") {
  return new EvidenceValidationError(message, { code, field: path, path });
}

function bytesEqual(left, right) {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function isZeroBlock(block) {
  for (const byte of block) {
    if (byte !== 0) return false;
  }
  return true;
}

function validateLimits(limits) {
  if (limits === null || typeof limits !== "object" || Array.isArray(limits)) {
    throw tarError("invalid_tar_limits", "TAR limits must be an object", "limits");
  }
  const result = {};
  for (const key of ["maxEntries", "maxEntryBytes", "maxTotalBytes", "maxArchiveBytes"]) {
    const value = limits[key];
    if (!Number.isSafeInteger(value) || value < 0) {
      throw tarError("invalid_tar_limits", `${key} must be a non-negative safe integer`, `limits.${key}`);
    }
    result[key] = value;
  }
  return result;
}

function asBuffer(value) {
  if (Buffer.isBuffer(value)) return value;
  if (value instanceof Uint8Array) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  }
  throw tarError("invalid_tar_input", "ZMR TAR input must be a Buffer or Uint8Array");
}

function parseOctal(field, code) {
  if (field.some((byte) => (byte & 0x80) !== 0)) {
    throw tarError(code, "Base-256 TAR numeric fields are not supported");
  }

  let index = 0;
  while (index < field.length && (field[index] === 0 || field[index] === 0x20)) index += 1;
  const start = index;
  while (index < field.length && field[index] >= 0x30 && field[index] <= 0x37) index += 1;
  const end = index;
  while (index < field.length && (field[index] === 0 || field[index] === 0x20)) index += 1;
  if (index !== field.length) {
    throw tarError(code, "Malformed TAR octal field");
  }
  if (start === end) return 0n;

  let value = 0n;
  for (let digit = start; digit < end; digit += 1) {
    value = (value * 8n) + BigInt(field[digit] - 0x30);
  }
  return value;
}

function readPathField(field, label) {
  let contentEnd = field.indexOf(0);
  if (contentEnd === -1) contentEnd = field.length;
  for (let index = contentEnd; index < field.length; index += 1) {
    if (field[index] !== 0) {
      throw tarError("unsafe_tar_path", `${label} contains an embedded NUL byte`);
    }
  }
  const content = field.subarray(0, contentEnd);
  for (const byte of content) {
    if (byte < 0x20 || byte === 0x7f) {
      throw tarError("unsafe_tar_path", `${label} contains a control byte`);
    }
  }
  try {
    return utf8Decoder.decode(content);
  } catch {
    throw tarError("unsafe_tar_path", `${label} is not valid UTF-8`);
  }
}

function validatedArchivePath(header) {
  const name = readPathField(header.subarray(0, 100), "TAR name");
  const prefix = readPathField(header.subarray(345, 500), "TAR prefix");
  const rawPath = prefix.length === 0 ? name : `${prefix}/${name}`;
  try {
    return assertSafeRelativePath(rawPath, "tar.path");
  } catch (error) {
    if (!(error instanceof EvidenceValidationError)) throw error;
    throw tarError("unsafe_tar_path", `Unsafe TAR entry path: ${rawPath}`);
  }
}

function validateHeaderFormat(header) {
  if (
    !bytesEqual(header.subarray(257, 263), USTAR_MAGIC)
    || !bytesEqual(header.subarray(263, 265), USTAR_VERSION)
  ) {
    throw tarError("invalid_tar_format", "Only POSIX ustar archives are supported");
  }
}

function validateChecksum(header) {
  const declared = parseOctal(header.subarray(148, 156), "invalid_tar_checksum");
  let actual = 0n;
  for (let index = 0; index < BLOCK_SIZE; index += 1) {
    actual += BigInt(index >= 148 && index < 156 ? 0x20 : header[index]);
  }
  if (declared !== actual) {
    throw tarError("invalid_tar_checksum", "TAR header checksum does not match");
  }
}

function validateRegularFileType(header) {
  const type = header[156];
  if (type !== 0 && type !== 0x30) {
    throw tarError(
      "unsupported_tar_entry_type",
      `Unsupported TAR entry type 0x${type.toString(16).padStart(2, "0")}`,
    );
  }
}

function inferContentType(path) {
  const name = path.slice(path.lastIndexOf("/") + 1).toLowerCase();
  const dot = name.lastIndexOf(".");
  return dot === -1 ? "application/octet-stream" : CONTENT_TYPES.get(name.slice(dot))
    ?? "application/octet-stream";
}

function comparePaths(left, right) {
  if (left.path < right.path) return -1;
  if (left.path > right.path) return 1;
  return 0;
}

export function parseZmrTar(buffer, limits = DEFAULT_TAR_LIMITS) {
  const bytes = asBuffer(buffer);
  const bounded = validateLimits(limits);
  if (bytes.length > bounded.maxArchiveBytes) {
    throw tarError("tar_archive_size_exceeded", "ZMR TAR exceeds the archive-size limit");
  }

  const entries = [];
  const acceptedPaths = new Set();
  let offset = 0;
  let totalBytes = 0n;
  let zeroBlocks = 0;

  while (offset < bytes.length) {
    if (offset + BLOCK_SIZE > bytes.length) {
      throw tarError("missing_tar_end_marker", "TAR archive ends without a complete end marker");
    }
    const header = bytes.subarray(offset, offset + BLOCK_SIZE);
    if (isZeroBlock(header)) {
      zeroBlocks += 1;
      offset += BLOCK_SIZE;
      if (zeroBlocks === 2) {
        for (let index = offset; index < bytes.length; index += 1) {
          if (bytes[index] !== 0) {
            throw tarError("trailing_tar_data", "TAR archive has non-zero data after its end marker");
          }
        }
        return entries.sort(comparePaths);
      }
      continue;
    }
    if (zeroBlocks !== 0) {
      throw tarError("missing_tar_end_marker", "TAR end marker must contain two consecutive zero blocks");
    }

    validateHeaderFormat(header);
    validateChecksum(header);
    validateRegularFileType(header);
    const archivePath = validatedArchivePath(header);
    if (acceptedPaths.has(archivePath)) {
      throw tarError("duplicate_tar_path", `Duplicate TAR entry path: ${archivePath}`);
    }
    if (entries.length >= bounded.maxEntries) {
      throw tarError("tar_entry_limit_exceeded", "ZMR TAR exceeds the entry-count limit");
    }

    const size = parseOctal(header.subarray(124, 136), "invalid_tar_size");
    if (size > BigInt(bounded.maxEntryBytes)) {
      throw tarError("tar_entry_size_exceeded", `TAR entry exceeds the per-entry limit: ${archivePath}`);
    }
    if (totalBytes + size > BigInt(bounded.maxTotalBytes)) {
      throw tarError("tar_total_size_exceeded", "ZMR TAR exceeds the cumulative content limit");
    }

    const dataStart = BigInt(offset + BLOCK_SIZE);
    const dataEnd = dataStart + size;
    const paddedEnd = dataStart + (((size + 511n) / 512n) * 512n);
    if (dataEnd > BigInt(bytes.length) || paddedEnd > BigInt(bytes.length)) {
      throw tarError("truncated_tar", `TAR entry body is truncated: ${archivePath}`);
    }

    const numericSize = Number(size);
    const numericStart = Number(dataStart);
    entries.push({
      path: archivePath,
      body: Buffer.from(bytes.subarray(numericStart, numericStart + numericSize)),
      sizeBytes: numericSize,
      contentType: inferContentType(archivePath),
    });
    acceptedPaths.add(archivePath);
    totalBytes += size;
    offset = Number(paddedEnd);
  }

  throw tarError("missing_tar_end_marker", "TAR archive is missing its end marker");
}
