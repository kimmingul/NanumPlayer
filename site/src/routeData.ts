import { defineRouteMiddleware } from '@astrojs/starlight/route-data';

const ALT: Record<string, string> = {
  en: 'NanumPlayer playing a video with AI subtitles in the target language',
  ko: 'AI 자막이 표시된 NanumPlayer 재생 화면',
};

// Social-preview image and its alt text, one per locale.
export const onRequest = defineRouteMiddleware((context) => {
  const route = context.locals.starlightRoute;
  const locale = route.locale === 'ko' ? 'ko' : 'en';
  const image = new URL(
    `${import.meta.env.BASE_URL}${locale === 'ko' ? 'og-image-ko.png' : 'og-image.png'}`,
    context.site,
  ).href;
  route.head.push(
    { tag: 'meta', attrs: { property: 'og:image', content: image } },
    { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
    { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
    { tag: 'meta', attrs: { property: 'og:image:alt', content: ALT[locale]! } },
    { tag: 'meta', attrs: { name: 'twitter:image', content: image } },
    { tag: 'meta', attrs: { name: 'twitter:image:alt', content: ALT[locale]! } },
  );
});
