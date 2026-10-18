NanumPlayer - Blu-ray/DVD decryption components (optional)
==========================================================

English
-------
This package is NOT part of the default NanumPlayer download. It contains the
libraries that NanumPlayer can use to read copy-protected discs:

  libaacs.dll         AACS (Blu-ray)            LGPL-2.1+   licenses\libaacs-COPYING
  libbdplus.dll       BD+  (Blu-ray)            LGPL-2.1+   licenses\libbdplus-COPYING
  libdvdcss-2.dll     CSS  (DVD)                GPL-2.0+    licenses\libdvdcss-COPYING

libaacs and libbdplus are built with libgcrypt and libgpg-error (LGPL-2.1+, see
licenses\). The corresponding source code and the build recipe are in sources\.
All of this software is third-party software; none of it is written by the NanumPlayer project.

Unprotected discs, disc folders and disc images play without this package.

Install: in NanumPlayer press Ctrl+N and choose "Blu-ray/DVD decryption
components", or open a protected disc and follow the prompt. You can download the
package there or install a copy you saved yourself (this ZIP, unchanged). The
installer of NanumPlayer also has an unchecked task for it. NanumPlayer only
accepts exactly the ZIP its own version pins (size and SHA-256) and checks every
file again before it is loaded. Files are installed to
%LOCALAPPDATA%\NanumPlayer\components\disc\<version>. Delete that folder to remove them.

AACS key database: only after this component is installed AND you agreed once,
NanumPlayer downloads the public FindVUK key database (fvonline-db.bplaced.net) when
a disc needs it. You can withdraw the agreement in Ctrl+N.

YOUR RESPONSIBILITY
Circumventing copy protection is restricted or prohibited by law in many countries
(for example by Article 6 of the EU Copyright Directive 2001/29/EC, section 1201 of
the US DMCA, and similar laws). The NanumPlayer project does not provide legal advice and
does not decide for you. By installing or using this package you confirm that you are
responsible for complying with the laws of your country, that you use it only with
discs you own or may lawfully use, and that you do not distribute copyrighted
material. The software is provided "as is" without any warranty (see the licenses).

한국어
------
이 패키지는 NanumPlayer 기본 배포본에 포함되어 있지 않은 선택 구성 요소입니다.
복제 방지가 걸린 디스크를 읽을 때 NanumPlayer가 사용할 수 있는 라이브러리가 들어 있습니다.

  libaacs.dll         AACS (Blu-ray)            LGPL-2.1+   licenses\libaacs-COPYING
  libbdplus.dll       BD+  (Blu-ray)            LGPL-2.1+   licenses\libbdplus-COPYING
  libdvdcss-2.dll     CSS  (DVD)                GPL-2.0+    licenses\libdvdcss-COPYING

libaacs와 libbdplus는 libgcrypt, libgpg-error(LGPL-2.1+, licenses\ 참조)로 빌드되었으며,
대응하는 소스 코드와 빌드 방법은 sources\ 에 있습니다. 모두 제3자 소프트웨어이며
NanumPlayer 프로젝트가 작성한 것이 아닙니다.

보호되지 않은 디스크, 디스크 폴더, 디스크 이미지는 이 패키지 없이도 재생됩니다.

설치: NanumPlayer에서 Ctrl+N > "Blu-ray/DVD 복호화 구성 요소"를 선택하거나, 보호된 디스크를
열었을 때 나타나는 안내를 따르세요. 거기서 내려받거나, 직접 저장해 둔 이 ZIP(변경하지 않은
것)로 설치할 수 있습니다. 설치 프로그램에도 선택 해제된 작업 항목이 있습니다. NanumPlayer는
자기 버전이 지정한(크기와 SHA-256) ZIP만 받아들이며, 불러오기 전에 모든 파일을 다시
검증합니다. 설치 위치는 %LOCALAPPDATA%\NanumPlayer\components\disc\<버전> 이며, 이 폴더를
지우면 제거됩니다.

AACS 키 DB: 이 구성 요소가 설치되어 있고 사용자가 한 번 동의한 경우에만, 디스크에 필요할 때
공개 FindVUK 키 데이터베이스(fvonline-db.bplaced.net)를 내려받습니다. 동의는 Ctrl+N에서
철회할 수 있습니다.

사용자의 책임
복제 방지의 우회는 많은 나라에서 법으로 제한되거나 금지됩니다(예: EU 저작권 지침
2001/29/EC 제6조, 미국 DMCA 제1201조, 이와 유사한 각국 법률). NanumPlayer 프로젝트는 법률
자문을 제공하지 않으며 사용자를 대신해 판단하지 않습니다. 이 패키지를 설치하거나 사용하면,
거주 국가의 법을 준수할 책임이 본인에게 있고, 본인이 소유했거나 합법적으로 이용할 수 있는
디스크에만 사용하며, 저작물을 배포하지 않는다는 데 동의한 것으로 봅니다. 소프트웨어는
어떠한 보증 없이 "있는 그대로" 제공됩니다(각 라이선스 참조).
