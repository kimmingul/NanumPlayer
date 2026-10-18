// Generates the social preview images public/og-image.png (English) and public/og-image-ko.png (Korean),
// 1200x630, from the logo, a localized headline and the hero screenshot.
// Run manually after changing the screenshots or texts:  node scripts/make-og.mjs
// Text needs a font with Latin and Hangul glyphs; on Windows "Segoe UI" and "Malgun Gothic" are used.
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';

const dir = (p) => fileURLToPath(new URL(p, import.meta.url));
const W = 1200;
const H = 630;

const variants = [
  {
    out: '../public/og-image.png',
    shot: '../src/assets/hero-en.png',
    title: 'NanumPlayer',
    lines: ['Watch anything in your language.', 'Real-time AI subtitles for Windows:', 'files, Blu-ray/DVD, YouTube and the web.'],
    foot: 'Free and open source · kimmingul.github.io/NanumPlayer',
  },
  {
    out: '../public/og-image-ko.png',
    shot: '../src/assets/hero-ko.png',
    title: 'NanumPlayer',
    lines: ['어떤 영상이든 내 언어로 보세요.', 'Windows용 실시간 AI 자막 플레이어:', '파일·디스크·YouTube·웹페이지 지원.'],
    foot: '무료 오픈 소스 · kimmingul.github.io/NanumPlayer/ko',
  },
];

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const font = "'Segoe UI','Malgun Gothic','Noto Sans CJK KR','Noto Sans',sans-serif";

for (const v of variants) {
  const shotW = 460;
  const shotH = Math.round((shotW * 9) / 16);
  const shot = await sharp(dir(v.shot))
    .resize(shotW, shotH)
    .composite([
      {
        input: Buffer.from(
          `<svg width="${shotW}" height="${shotH}"><rect width="${shotW}" height="${shotH}" rx="14" ry="14"/></svg>`,
        ),
        blend: 'dest-in',
      },
    ])
    .png()
    .toBuffer();
  const logo = await sharp(dir('../src/assets/logo.svg')).resize(112, 112).png().toBuffer();
  const text = lines(v.lines);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
    <defs>
      <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#0b1b33"/><stop offset="1" stop-color="#16294d"/>
      </linearGradient>
    </defs>
    <rect width="${W}" height="${H}" fill="url(#bg)"/>
    <text x="156" y="128" font-family="${font}" font-size="64" font-weight="700" fill="#ffffff">${esc(v.title)}</text>
    ${text}
    <text x="64" y="${H - 44}" font-family="${font}" font-size="24" fill="#8fd8ff">${esc(v.foot)}</text>
  </svg>`;
  function lines(ls) {
    return ls
      .map(
        (l, i) =>
          `<text x="64" y="${250 + i * 52}" font-family="${font}" font-size="${i === 0 ? 34 : 28}" fill="${i === 0 ? '#ffffff' : '#c9d6ee'}" font-weight="${i === 0 ? 600 : 400}">${esc(l)}</text>`,
      )
      .join('');
  }
  const shadow = await sharp({
    create: { width: shotW + 40, height: shotH + 40, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([
      {
        input: Buffer.from(
          `<svg width="${shotW + 40}" height="${shotH + 40}"><rect x="20" y="28" width="${shotW}" height="${shotH}" rx="14" fill="#000" fill-opacity="0.55"/></svg>`,
        ),
      },
    ])
    .blur(14)
    .png()
    .toBuffer();
  await sharp(Buffer.from(svg))
    .composite([
      { input: logo, left: 28, top: 38 },
      { input: shadow, left: W - shotW - 68, top: 250 },
      { input: shot, left: W - shotW - 48, top: 270 },
    ])
    .png({ palette: true, quality: 92 })
    .toFile(dir(v.out));
  console.log('wrote', v.out);
}
