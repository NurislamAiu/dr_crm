/**
 * Перекодировка голосовых для WhatsApp.
 *
 * Приложение пишет голосовое в M4A (AAC) — единственный формат, который умеют
 * и iOS, и Android. Канал WABA такой файл не принимает: Meta отбивала его с
 * WRONG_CONTENT («тип не поддерживается мессенджером»). OGG/Opus, родной
 * формат голосовых WhatsApp, тоже отбивался.
 *
 * Разгадка нашлась в самом Wazzup: голосовое, отправленное из их интерфейса,
 * ушло файлом «wazzup_audio.mp3» — их WABA-канал шлёт аудио как MP3. Поэтому
 * конвертируем в MP3 (audio/mpeg, он же в списке поддерживаемых у Meta).
 *
 * Конвертация — «лучшее усилие»: если ffmpeg почему-то недоступен, отправляем
 * исходный файл (лучше попытка, чем потерянное сообщение).
 */
import * as admin from "firebase-admin";
import { execFile } from "child_process";
import { promises as fs } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { promisify } from "util";

const run = promisify(execFile);

/**
 * Прямая ссылка на файл в Storage.
 *
 * Раньше вложения уходили ссылкой на нашу функцию mediaContent — из
 * интерфейса Wazzup то же аудио отправлялось нормально, а через API
 * возвращалось WRONG_CONTENT. Отдаём обычный статический файл Google:
 * настоящее имя с расширением в пути, Range и Content-Type «из коробки»,
 * без холодного старта функции.
 *
 * Сначала пробуем подписанную ссылку (файл остаётся закрытым), если
 * подписывать нечем — делаем объект публичным. null — не вышло ни то, ни
 * другое, вызывающий код останется на старой ссылке.
 */
export async function publicMediaUrl(path: string): Promise<string | null> {
  const bucket = admin.storage().bucket();
  const file = bucket.file(path);
  try {
    const [url] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + 7 * 24 * 3600 * 1000,
      version: "v4",
    });
    return url;
  } catch (e) {
    console.warn("publicMediaUrl: подпись недоступна", String(e instanceof Error ? e.message : e));
  }
  try {
    await file.makePublic();
    return `https://storage.googleapis.com/${bucket.name}/${path.split("/").map(encodeURIComponent).join("/")}`;
  } catch (e) {
    console.error("publicMediaUrl fail", path, String(e instanceof Error ? e.message : e));
    return null;
  }
}

/** Путь к бинарнику ffmpeg (пакет ставит сборку под платформу рантайма). */
function ffmpegPath(): string | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require("@ffmpeg-installer/ffmpeg") as { path?: string };
    return mod.path ?? null;
  } catch {
    return null;
  }
}

/**
 * Конвертирует аудио из Storage в MP3 и кладёт рядом. Возвращает путь нового
 * файла или null, если конвертация не удалась.
 *
 * Результат кэшируем в самом Storage: повтор отправки того же файла (ретрай
 * очереди) не запускает ffmpeg заново.
 */
export async function toWhatsAppAudio(mediaPath: string): Promise<string | null> {
  if (mediaPath.toLowerCase().endsWith(".mp3")) return mediaPath;
  const bin = ffmpegPath();
  if (!bin) {
    console.error("toWhatsAppAudio: ffmpeg недоступен");
    return null;
  }

  const bucket = admin.storage().bucket();
  const outPath = `${mediaPath.replace(/\.[^./]+$/, "")}.mp3`;
  const outFile = bucket.file(outPath);
  if ((await outFile.exists())[0]) return outPath;

  const base = join(tmpdir(), `a_${Date.now()}`);
  const src = `${base}_in`;
  const dst = `${base}_out.mp3`;
  try {
    await bucket.file(mediaPath).download({ destination: src });
    // Моно 44.1 кГц 64 кбит/с — речь звучит так же, файл в разы меньше.
    await run(bin, ["-hide_banner", "-loglevel", "error", "-y", "-i", src,
      "-vn", "-c:a", "libmp3lame", "-b:a", "64k", "-ar", "44100", "-ac", "1", dst], { timeout: 60_000 });
    await bucket.upload(dst, { destination: outPath, metadata: { contentType: "audio/mpeg" } });
    return outPath;
  } catch (e) {
    console.error("toWhatsAppAudio fail", mediaPath, String(e instanceof Error ? e.message : e));
    return null;
  } finally {
    await fs.rm(src, { force: true }).catch(() => {});
    await fs.rm(dst, { force: true }).catch(() => {});
  }
}
