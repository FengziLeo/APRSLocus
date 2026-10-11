#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""向 6 个 ARB 注入「智能体授权 / 申请页」的文案。

智能体不对普通用户开放：未授权时弹这一页，说明「为什么受限 / 怎么申请 /
怎么生效」。文本级插入，幂等可重复执行 —— 同 tool/add_*_l10n.py 的既有约定。
⚠ ICU：译文里不要出现落单的半角单引号。
"""
import io
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DATA = {
    'agentAuthTitle': {
        'zh': '智能体需要授权', 'zh_TW': '智慧體需要授權',
        'en': 'The Agent needs authorization',
        'ja': 'エージェントには認可が必要です',
        'id': 'Agen memerlukan otorisasi',
        'es': 'El agente requiere autorización',
    },
    'agentAuthBody': {
        'zh': '智能体不对普通用户开放。请下载并填写承诺书，发送到下方邮箱；'
              '审核通过后，你的呼号会被加入授权名单，软件会从官网自动拉取。',
        'zh_TW': '智慧體不對一般使用者開放。請下載並填寫承諾書，寄到下方信箱；'
                 '審核通過後，你的呼號會被加入授權名單，軟體會從官網自動取得。',
        'en': 'The Agent is not open to ordinary users. Download and fill in the letter '
              'of commitment, then email it to the address below. Once approved, your '
              'call sign is added to the authorization list, which the app pulls from '
              'the official site.',
        'ja': 'エージェントは一般ユーザーには公開されていません。承諾書をダウンロードして'
              '記入し、下記のメールアドレスへ送信してください。承認されると、あなたの'
              'コールサインが認可リストに追加され、アプリが公式サイトから取得します。',
        'id': 'Agen tidak terbuka untuk pengguna umum. Unduh dan isi surat pernyataan, '
              'lalu kirim ke alamat surel di bawah. Setelah disetujui, callsign Anda '
              'ditambahkan ke daftar otorisasi, yang diambil aplikasi dari situs resmi.',
        'es': 'El agente no está abierto a usuarios comunes. Descarga y completa la carta '
              'de compromiso y envíala a la dirección de abajo. Una vez aprobada, tu '
              'indicativo se añade a la lista de autorización, que la app obtiene del '
              'sitio oficial.',
    },
    'agentAuthCallLabel': {
        'zh': '本机呼号', 'zh_TW': '本機呼號', 'en': 'This device call sign',
        'ja': 'この端末のコールサイン', 'id': 'Callsign perangkat ini',
        'es': 'Indicativo de este dispositivo',
    },
    'agentAuthStep1Title': {
        'zh': '下载承诺书', 'zh_TW': '下載承諾書', 'en': 'Download the letter',
        'ja': '承諾書をダウンロード', 'id': 'Unduh surat pernyataan',
        'es': 'Descarga la carta',
    },
    'agentAuthStep1Desc': {
        'zh': '点下方「下载承诺书」，用浏览器打开官方承诺书全文。',
        'zh_TW': '點下方「下載承諾書」，用瀏覽器開啟官方承諾書全文。',
        'en': 'Tap "Download the letter" below to open the official letter in your browser.',
        'ja': '下の「承諾書をダウンロード」をタップすると、ブラウザで承諾書全文が開きます。',
        'id': 'Ketuk "Unduh surat pernyataan" di bawah untuk membuka surat resmi di peramban.',
        'es': 'Toca "Descargar la carta" abajo para abrir la carta oficial en el navegador.',
    },
    'agentAuthStep2Title': {
        'zh': '填写并发送', 'zh_TW': '填寫並寄送', 'en': 'Fill in and send',
        'ja': '記入して送信', 'id': 'Isi dan kirim', 'es': 'Completa y envía',
    },
    'agentAuthStep2Desc': {
        'zh': '如实填写承诺书后，把邮件发送到：',
        'zh_TW': '如實填寫承諾書後，把郵件寄到：',
        'en': 'After filling it in truthfully, email it to:',
        'ja': '承諾書に記入のうえ、次の宛先へ送信してください：',
        'id': 'Setelah mengisinya dengan benar, kirim surel ke:',
        'es': 'Tras completarla con veracidad, envíala por correo a:',
    },
    'agentAuthStep3Title': {
        'zh': '等待审核并重新检查', 'zh_TW': '等待審核並重新檢查',
        'en': 'Wait for review, then check again',
        'ja': '審査後に再確認', 'id': 'Tunggu peninjauan, lalu periksa lagi',
        'es': 'Espera la revisión y vuelve a comprobar',
    },
    'agentAuthStep3Desc': {
        'zh': '审核通过后点「重新检查」即可启用；名单与封禁名单同一套架构，从官网拉取。',
        'zh_TW': '審核通過後點「重新檢查」即可啟用；名單與封禁名單同一套架構，從官網取得。',
        'en': 'Once approved, tap "Check again" to enable it. The list uses the same '
              'architecture as the blocklist and is pulled from the official site.',
        'ja': '承認後「再確認」をタップすると有効になります。リストはブロックリストと同じ'
              '仕組みで、公式サイトから取得します。',
        'id': 'Setelah disetujui, ketuk "Periksa lagi" untuk mengaktifkan. Daftar ini '
              'memakai arsitektur yang sama dengan daftar blokir dan diambil dari situs resmi.',
        'es': 'Una vez aprobada, toca "Comprobar de nuevo" para activarlo. La lista usa la '
              'misma arquitectura que la lista de bloqueo y se obtiene del sitio oficial.',
    },
    'agentAuthDownload': {
        'zh': '下载承诺书', 'zh_TW': '下載承諾書', 'en': 'Download the letter',
        'ja': '承諾書をダウンロード', 'id': 'Unduh surat pernyataan',
        'es': 'Descargar la carta',
    },
    'agentAuthEmail': {
        'zh': '用邮件发送', 'zh_TW': '用郵件寄送', 'en': 'Send by email',
        'ja': 'メールで送信', 'id': 'Kirim lewat surel', 'es': 'Enviar por correo',
    },
    'agentAuthMailTo': {
        'zh': '申请邮箱：', 'zh_TW': '申請信箱：', 'en': 'Apply to:',
        'ja': '申請先：', 'id': 'Ajukan ke:', 'es': 'Solicitar a:',
    },
    'agentAuthMailSubject': {
        'zh': '智能体授权申请', 'zh_TW': '智慧體授權申請',
        'en': 'Agent authorization request', 'ja': 'エージェント認可申請',
        'id': 'Permohonan otorisasi agen',
        'es': 'Solicitud de autorización del agente',
    },
    'agentAuthMailBody': {
        'zh': '你好，我申请使用 APRSLocus 智能体功能，并已按承诺书内容如实填写、'
              '承诺遵守相关约定。我的呼号如下：',
        'zh_TW': '你好，我申請使用 APRSLocus 智慧體功能，並已依承諾書內容如實填寫、'
                 '承諾遵守相關約定。我的呼號如下：',
        'en': 'Hello, I would like to use the APRSLocus Agent feature. I have filled in the '
              'letter of commitment truthfully and agree to its terms. My call sign:',
        'ja': 'こんにちは。APRSLocus のエージェント機能の利用を申請します。承諾書の内容を'
              '正確に記入し、遵守することを約束します。私のコールサインは次のとおりです：',
        'id': 'Halo, saya ingin menggunakan fitur Agen APRSLocus. Saya telah mengisi surat '
              'pernyataan dengan benar dan menyetujui ketentuannya. Callsign saya:',
        'es': 'Hola, quiero usar la función de agente de APRSLocus. He completado la carta '
              'de compromiso con veracidad y acepto sus términos. Mi indicativo:',
    },
    'agentAuthRecheck': {
        'zh': '重新检查授权', 'zh_TW': '重新檢查授權', 'en': 'Check authorization again',
        'ja': '認可を再確認', 'id': 'Periksa otorisasi lagi',
        'es': 'Comprobar autorización de nuevo',
    },
    'agentAuthChecking': {
        'zh': '正在检查…', 'zh_TW': '檢查中…', 'en': 'Checking…',
        'ja': '確認中…', 'id': 'Memeriksa…', 'es': 'Comprobando…',
    },
    'agentAuthBack': {
        'zh': '暂不启用', 'zh_TW': '暫不啟用', 'en': 'Not now',
        'ja': '今はしない', 'id': 'Nanti saja', 'es': 'Ahora no',
    },
    'agentAuthGranted': {
        'zh': '已获授权，智能体已启用', 'zh_TW': '已獲授權，智慧體已啟用',
        'en': 'Authorization confirmed - the Agent is now enabled',
        'ja': '認可を確認しました。エージェントを有効にしました',
        'id': 'Otorisasi terkonfirmasi - Agen kini aktif',
        'es': 'Autorización confirmada: el agente ya está activado',
    },
    'agentAuthStillPending': {
        'zh': '暂未查到授权，可能仍在审核中', 'zh_TW': '暫未查到授權，可能仍在審核中',
        'en': 'No authorization found yet; your request may still be under review',
        'ja': 'まだ認可を確認できません。審査中かもしれません',
        'id': 'Otorisasi belum ditemukan; permohonan Anda mungkin masih ditinjau',
        'es': 'Aún no se encuentra autorización; tu solicitud puede seguir en revisión',
    },
    'agentAuthHint': {
        'zh': '智能体功能需要授权后才能使用，本机呼号不在授权名单中。',
        'zh_TW': '智慧體功能需要授權後才能使用，本機呼號不在授權名單中。',
        'en': 'The Agent feature requires authorization; this call sign is not on the '
              'authorization list.',
        'ja': 'エージェント機能の利用には認可が必要です。このコールサインは認可リストに'
              'ありません。',
        'id': 'Fitur Agen memerlukan otorisasi; callsign ini tidak ada dalam daftar '
              'otorisasi.',
        'es': 'La función de agente requiere autorización; este indicativo no está en la '
              'lista de autorización.',
    },
}

LANGS = ['zh', 'zh_TW', 'en', 'ja', 'id', 'es']
ANCHOR = '"blTitle"'


def main():
    for lang in LANGS:
        path = os.path.join(ROOT, 'lib/l10n/app_%s.arb' % lang)
        lines = io.open(path, encoding='utf-8').read().split('\n')
        keep = [ln for ln in lines
                if not any(ln.strip().startswith('"%s"' % k) for k in DATA)]
        idx = next(i for i, ln in enumerate(keep)
                   if ln.strip().startswith(ANCHOR))
        block = ['  "%s": %s,' % (k, json.dumps(tr[lang], ensure_ascii=False))
                 for k, tr in DATA.items()]
        keep[idx + 1:idx + 1] = block
        io.open(path, 'w', encoding='utf-8').write('\n'.join(keep))
        d = json.loads(io.open(path, encoding='utf-8').read())
        print('%s ok, %d keys' % (os.path.basename(path),
                                  len([k for k in d if not k.startswith('@')])))


if __name__ == '__main__':
    main()
