// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Project page: https://kimmingul.github.io/NanumPlayer/ (English, root) and /ko/ (Korean).
export default defineConfig({
  site: 'https://kimmingul.github.io',
  base: '/NanumPlayer/',
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'NanumPlayer',
      description:
        'A native Windows media player that recognizes and translates dialogue in real time and shows it as subtitles.',
      logo: { src: './src/assets/logo.svg', alt: '' },
      favicon: '/favicon.svg',
      defaultLocale: 'root',
      locales: {
        root: { label: 'English', lang: 'en' },
        ko: { label: '한국어', lang: 'ko' },
      },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/kimmingul/NanumPlayer' },
      ],
      editLink: { baseUrl: 'https://github.com/kimmingul/NanumPlayer/edit/main/site/' },
      customCss: ['./src/styles/custom.css'],
      components: {
        Banner: './src/components/LangHint.astro',
      },
      routeMiddleware: './src/routeData.ts',
      sidebar: [
        { slug: 'getting-started', translations: { ko: '시작하기' } },
        {
          label: 'Features',
          translations: { ko: '기능' },
          items: [
            { slug: 'features', translations: { ko: '기능 개요' } },
            { slug: 'features/ai-subtitles', translations: { ko: 'AI 자막' } },
            { slug: 'features/subtitle-list', translations: { ko: '자막 목록' } },
            { slug: 'features/generate-subtitles', translations: { ko: '자막 파일 만들기' } },
            { slug: 'features/ocr-online-subtitles', translations: { ko: '이미지 자막 OCR·온라인 자막' } },
            { slug: 'features/glossary', translations: { ko: '용어집과 번역 말투' } },
            { slug: 'features/upscaling', translations: { ko: '영상 업스케일' } },
            { slug: 'features/picture-quality', translations: { ko: '영상 화질 보정' } },
            { slug: 'features/youtube-web', translations: { ko: 'YouTube·웹페이지' } },
          ],
        },
        {
          slug: 'disc-decryption',
          translations: { ko: 'Blu-ray/DVD 복호화 구성 요소' },
        },
        { slug: 'faq', translations: { ko: '자주 묻는 질문' } },
        { slug: 'privacy', translations: { ko: '개인정보 보호' } },
        { slug: 'changelog', translations: { ko: '변경 내역' } },
        { slug: 'license', translations: { ko: '라이선스와 고지' } },
      ],
    }),
  ],
});
