import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const decoder = new TextDecoder("utf-8", { fatal: true });

export const normalizeLineEndings = (value) => value.replace(/\r\n?/g, "\n");

export const readNormalizedUtf8 = (path) =>
  normalizeLineEndings(decoder.decode(readFileSync(path)));

export const hashNormalizedText = (algorithm, value) =>
  createHash(algorithm)
    .update(normalizeLineEndings(value), "utf8")
    .digest("hex");
