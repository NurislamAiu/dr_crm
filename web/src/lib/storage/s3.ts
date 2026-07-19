import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  HeadBucketCommand,
  CreateBucketCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { getEnv } from "@/lib/env";

/**
 * S3-совместимое хранилище (MinIO в dev). Медиа храним у себя, а не отдаём
 * ссылки Wazzup напрямую (ТЗ §10). Signed URL — короткоживущие (§10, §24).
 */

let client: S3Client | null = null;
let bucketEnsured = false;

function cfg() {
  const env = getEnv();
  return {
    endpoint: env.STORAGE_ENDPOINT ?? "http://localhost:9000",
    bucket: env.STORAGE_BUCKET ?? "crm-media",
    accessKeyId: env.STORAGE_ACCESS_KEY ?? "minioadmin",
    secretAccessKey: env.STORAGE_SECRET_KEY ?? "minioadmin",
  };
}

export function getS3(): S3Client {
  if (client) return client;
  const c = cfg();
  client = new S3Client({
    region: "us-east-1",
    endpoint: c.endpoint,
    credentials: { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey },
    forcePathStyle: true, // обязательно для MinIO
  });
  return client;
}

export function bucketName(): string {
  return cfg().bucket;
}

export async function ensureBucket(): Promise<void> {
  if (bucketEnsured) return;
  const s3 = getS3();
  const Bucket = bucketName();
  try {
    await s3.send(new HeadBucketCommand({ Bucket }));
  } catch {
    try {
      await s3.send(new CreateBucketCommand({ Bucket }));
    } catch {
      // мог создаться параллельно — игнорируем
    }
  }
  bucketEnsured = true;
}

export async function putObject(
  key: string,
  body: Uint8Array,
  contentType: string,
): Promise<void> {
  await ensureBucket();
  await getS3().send(
    new PutObjectCommand({
      Bucket: bucketName(),
      Key: key,
      Body: body,
      ContentType: contentType,
    }),
  );
}

/** Короткоживущий signed GET URL (по умолчанию 5 минут). */
export async function signedGetUrl(key: string, ttlSeconds = 300): Promise<string> {
  return getSignedUrl(
    getS3(),
    new GetObjectCommand({ Bucket: bucketName(), Key: key }),
    { expiresIn: ttlSeconds },
  );
}

/** Считать объект целиком в байты (для проксирования через backend). */
export async function getObjectBytes(key: string): Promise<Uint8Array> {
  const res = await getS3().send(new GetObjectCommand({ Bucket: bucketName(), Key: key }));
  if (!res.Body) throw new Error("Пустое тело объекта");
  return res.Body.transformToByteArray();
}
