#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注入「智能体 v2」相关文案（6 语言）：设置页分页、Always-allow、定时任务、自动回复。

与 add_agent_l10n.py 同一套路数（arb 真源 + 抽象类 + 6 个 gen-l10n 产物）。

用法：python3 tool/add_agent_v2_l10n.py
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ['zh', 'zh_TW', 'en', 'ja', 'es', 'id']
IDX = {l: i for i, l in enumerate(LANGS)}
CLASSES = {
    'zh': 'AppLocalizationsZh', 'zh_TW': 'AppLocalizationsZhTw',
    'en': 'AppLocalizationsEn', 'ja': 'AppLocalizationsJa',
    'es': 'AppLocalizationsEs', 'id': 'AppLocalizationsId',
}

# key → (zh, zh_TW, en, ja, es, id)
DATA = {
    'agentTabConnection': ('连接', '連線', 'Connection', '接続', 'Conexión', 'Koneksi'),
    'agentTabPermissions': ('权限', '權限', 'Permissions', '権限', 'Permisos', 'Izin'),
    'agentTabAutomation': ('自动化', '自動化', 'Automation', '自動化', 'Automatización', 'Otomatisasi'),
    'agentSystemPromptHint': ('留空则使用内置提示', '留空則使用內建提示',
                              'Leave empty to use the built-in prompt', '空欄なら内蔵プロンプトを使用',
                              'Déjalo vacío para usar el prompt integrado', 'Kosongkan untuk prompt bawaan'),
    'agentAlwaysAllow': ('始终允许', '一律允許', 'Always allow', '常に許可', 'Permitir siempre', 'Selalu izinkan'),
    'agentAlwaysAllowDesc': (
        '已放行的工具，执行时不再询问。在确认条上点「始终允许」可加入此列表。',
        '已放行的工具，執行時不再詢問。在確認條上點「一律允許」可加入此清單。',
        'These tools run without asking. Tap “Always allow” on the confirm bar to add one.',
        '許可済みのツールは確認なしで実行されます。確認バーの「常に許可」で追加できます。',
        'Estas herramientas se ejecutan sin preguntar. Pulsa «Permitir siempre» para añadir una.',
        'Alat ini berjalan tanpa bertanya. Ketuk "Selalu izinkan" pada bilah konfirmasi untuk menambah.'),
    'agentAlwaysAllowEmpty': ('暂无。在操作确认条上点「始终允许」即可添加。', '暫無。在操作確認條上點「一律允許」即可加入。',
                              'None yet. Tap “Always allow” on a confirm bar to add one.',
                              'まだありません。確認バーの「常に許可」で追加できます。',
                              'Ninguna aún. Pulsa «Permitir siempre» en una barra de confirmación.',
                              'Belum ada. Ketuk "Selalu izinkan" pada bilah konfirmasi.'),
    'agentAlwaysAllowClear': ('清除全部放行', '清除全部放行', 'Clear all', 'すべて消去', 'Borrar todo', 'Hapus semua'),
    'agentAutoReply': ('自动回复', '自動回覆', 'Auto reply', '自動返信', 'Respuesta automática', 'Balasan otomatis'),
    'agentAutoReplyDesc': ('收到新消息时让智能体自动回一条（实验）', '收到新訊息時讓智慧代理自動回一條（實驗）',
                           'Let the agent answer new messages automatically (experimental)',
                           '新着メッセージにエージェントが自動返信します（実験的）',
                           'El agente responde solo a los mensajes nuevos (experimental)',
                           'Agen membalas pesan baru secara otomatis (eksperimental)'),
    'agentAutoReplyOn': ('启用自动回复', '啟用自動回覆', 'Enable auto reply', '自動返信を有効化',
                         'Activar respuesta automática', 'Aktifkan balasan otomatis'),
    'agentAutoReplyHint': (
        '仅回复私聊；受安静时段与冷却限制；需开启「允许发送消息」。',
        '僅回覆私聊；受安靜時段與冷卻限制；需開啟「允許傳送訊息」。',
        'Direct messages only; limited by quiet hours and a cooldown; requires “Allow sending messages”.',
        'DM のみ。静音時間とクールダウンの対象。メッセージ送信の許可が必要です。',
        'Solo mensajes directos; sujeto a horas de silencio y enfriamiento; requiere «Permitir enviar mensajes».',
        'Hanya pesan langsung; dibatasi jam tenang dan jeda; perlu "Izinkan mengirim pesan".'),
    'agentReplyGroups': ('也回复群聊', '也回覆群聊', 'Also reply in groups', 'グループにも返信',
                         'Responder también en grupos', 'Balas juga di grup'),
    'agentReplyGroupsDesc': ('群里自动说话风险更大，默认关闭', '群裡自動說話風險較大，預設關閉',
                             'Speaking automatically in groups is riskier; off by default',
                             'グループでの自動発言はリスクが高いため既定でオフ',
                             'Hablar automáticamente en grupos es más arriesgado; desactivado por defecto',
                             'Bicara otomatis di grup lebih berisiko; mati secara bawaan'),
    'agentQuietHours': ('安静时段', '安靜時段', 'Quiet hours', '静音時間', 'Horas de silencio', 'Jam tenang'),
    'agentQuietHoursDesc': ('形如 23:00-07:00；留空=不限。此时间段内不自动回复。', '形如 23:00-07:00；留空=不限。此時段內不自動回覆。',
                            'e.g. 23:00-07:00; empty = no limit. No auto reply in this window.',
                            '例 23:00-07:00。空欄＝制限なし。この時間帯は自動返信しません。',
                            'p. ej. 23:00-07:00; vacío = sin límite. No responde en esa franja.',
                            'mis. 23:00-07:00; kosong = tanpa batas. Tidak membalas di rentang ini.'),
    'agentTasks': ('定时任务', '定時任務', 'Scheduled tasks', 'スケジュールタスク', 'Tareas programadas', 'Tugas terjadwal'),
    'agentTasksDesc': ('到点让智能体自动跑一段指令', '到點讓智慧代理自動跑一段指令',
                       'Run an instruction later automatically',
                       '指定時刻にエージェントが指示を自動実行します',
                       'Ejecuta una instrucción más tarde automáticamente',
                       'Jalankan instruksi nanti secara otomatis'),
    'agentTasksEmpty': ('暂无定时任务', '暫無定時任務', 'No scheduled tasks yet', 'スケジュールタスクはありません',
                        'Aún no hay tareas programadas', 'Belum ada tugas terjadwal'),
    'agentTaskNew': ('新建定时任务', '新建定時任務', 'New scheduled task', 'スケジュールタスクを追加',
                     'Nueva tarea programada', 'Tugas terjadwal baru'),
    'agentTaskPrompt': ('指令', '指令', 'Instruction', '指示', 'Instrucción', 'Instruksi'),
    'agentTaskPromptHint': ('例如：总结最近一小时的台站', '例如：總結最近一小時的台站',
                            'e.g. summarize stations heard in the last hour',
                            '例：直近1時間に受信した局を要約',
                            'p. ej. resume las estaciones de la última hora',
                            'mis. ringkas stasiun satu jam terakhir'),
    'agentTaskInterval': ('间隔（分钟）', '間隔（分鐘）', 'Interval (minutes)', '間隔（分）', 'Intervalo (minutos)',
                          'Interval (menit)'),
    'agentTaskIntervalHint': ('0 = 只跑一次；循环最短 1 分钟', '0 = 只跑一次；循環最短 1 分鐘',
                              '0 = run once; repeating min 1 min', '0 = 1 回のみ。繰り返しは最短 1 分',
                              '0 = una vez; repetir mínimo 1 min', '0 = sekali; ulang min 1 menit'),
    'agentTaskCreate': ('创建', '建立', 'Create', '作成', 'Crear', 'Buat'),
    'agentTaskDelete': ('删除', '刪除', 'Delete', '削除', 'Eliminar', 'Hapus'),
    'agentTaskEvery': ('每 {n} 分钟', '每 {n} 分鐘', 'Every {n} min', '{n} 分ごと', 'Cada {n} min',
                       'Setiap {n} menit'),
    'agentTaskOnce': ('只跑一次', '只跑一次', 'Once', '1 回のみ', 'Una vez', 'Sekali'),
    'agentAutoReplyPrompt': (
        '【自动回复】{from} 发来消息：{text}\n你可以调用只读工具（查台站、消息等）获取事实，但不要执行任何改动设置或发送消息的操作。最终只输出要回复给对方的那一句话。',
        '【自動回覆】{from} 傳來訊息：{text}\n你可以呼叫唯讀工具（查局、訊息等）取得事實，但不要執行任何變更設定或傳送訊息的動作。最終只輸出要回覆給對方的那一句話。',
        '[Auto reply] {from} sent you: {text}\nYou may call read-only tools (stations, messages, …) for facts, but do not change settings or send anything. Output only the single message to send back.',
        '【自動返信】{from} からのメッセージ：{text}\n読み取り専用ツール（局・メッセージなど）で事実を調べてもよいですが、設定変更や送信はしないでください。返信する一文だけを出力してください。',
        '[Respuesta automática] {from} te escribió: {text}\nPuedes usar herramientas de solo lectura (estaciones, mensajes…) para obtener datos, pero no cambies ajustes ni envíes nada. Escribe solo el mensaje a responder.',
        '[Balasan otomatis] {from} mengirim: {text}\nKamu boleh memakai alat hanya-baca (stasiun, pesan, …) untuk fakta, tapi jangan mengubah setelan atau mengirim apa pun. Keluarkan hanya pesan balasan.'),
    # 工具名的人类可读称呼（避免界面直接显示 get_app_state 这类带下划线的标识符）
    'agentTool_get_app_state': ('读取应用状态', '讀取應用狀態', 'Read app state', 'アプリ状態を取得',
                                'Leer estado de la app', 'Baca status aplikasi'),
    'agentTool_list_groups': ('列出群组', '列出群組', 'List groups', 'グループ一覧', 'Listar grupos',
                              'Daftar grup'),
    'agentTool_search_stations': ('搜索台站', '搜尋台站', 'Search stations', '局を検索',
                                  'Buscar estaciones', 'Cari stasiun'),
    'agentTool_list_stations': ('列出台站', '列出台站', 'List stations', '局を一覧', 'Listar estaciones',
                                'Daftar stasiun'),
    'agentTool_station_detail': ('台站详情', '台站詳情', 'Station details', '局の詳細',
                                 'Detalles de estación', 'Detail stasiun'),
    'agentTool_read_messages': ('读取消息', '讀取訊息', 'Read messages', 'メッセージを読む',
                                'Leer mensajes', 'Baca pesan'),
    'agentTool_send_message': ('发送消息', '傳送訊息', 'Send message', 'メッセージ送信', 'Enviar mensaje',
                               'Kirim pesan'),
    'agentTool_send_beacon_now': ('立即发送信标', '立即傳送信標', 'Send beacon now', '今すぐビーコン送信',
                                  'Enviar baliza ahora', 'Kirim beacon sekarang'),
    'agentTool_set_preferences': ('修改偏好设置', '修改偏好設定', 'Change preferences', '環境設定を変更',
                                  'Cambiar preferencias', 'Ubah preferensi'),
    'agentTool_set_station_filters': ('修改台站过滤', '修改台站過濾', 'Change station filters',
                                      '局フィルタを変更', 'Cambiar filtros de estaciones',
                                      'Ubah filter stasiun'),
    'agentTool_set_nickname': ('修改呼号信息', '修改呼號資訊', 'Change callsign info', 'コールサイン情報を変更',
                               'Cambiar datos de indicativo', 'Ubah info callsign'),
    'agentTool_navigate': ('切换页面', '切換頁面', 'Switch screen', '画面を切り替え', 'Cambiar de pantalla',
                           'Ganti layar'),
    'agentTool_create_task': ('新建定时任务', '新建定時任務', 'Create scheduled task', 'スケジュールタスク作成',
                              'Crear tarea programada', 'Buat tugas terjadwal'),
    'agentTool_list_tasks': ('列出定时任务', '列出定時任務', 'List scheduled tasks', 'スケジュールタスク一覧',
                             'Listar tareas programadas', 'Daftar tugas terjadwal'),
    'agentTool_cancel_task': ('取消定时任务', '取消定時任務', 'Cancel scheduled task', 'スケジュールタスク取消',
                              'Cancelar tarea programada', 'Batalkan tugas terjadwal'),
    'agentTool_set_connection_server': ('修改服务器地址', '修改伺服器位址', 'Change server address',
                                        'サーバーを変更', 'Cambiar servidor', 'Ubah alamat server'),
    'agentTool_set_connection_source': ('修改连接方式', '修改連線方式', 'Change connection source',
                                        '接続方法を変更', 'Cambiar fuente de conexión',
                                        'Ubah sumber koneksi'),
    'agentTool_connect': ('连接', '連線', 'Connect', '接続', 'Conectar', 'Hubungkan'),
    'agentTool_disconnect': ('断开连接', '中斷連線', 'Disconnect', '切断', 'Desconectar',
                             'Putuskan'),
    'agentTool_nearby_stations': ('附近台站', '附近台站', 'Nearby stations', '近くの局',
                                  'Estaciones cercanas', 'Stasiun terdekat'),
    'agentTool_reply_message': ('回复消息', '回覆訊息', 'Reply to message', 'メッセージに返信',
                                'Responder mensaje', 'Balas pesan'),
    'agentTool_send_group_message': ('群发消息', '群發訊息', 'Send group message',
                                     'グループへ送信', 'Enviar a grupo', 'Kirim ke grup'),
    'agentTool_create_group': ('创建群组', '建立群組', 'Create group', 'グループを作成',
                               'Crear grupo', 'Buat grup'),
    'agentTool_set_task_enabled': ('暂停/恢复任务', '暫停/恢復任務', 'Pause/resume task',
                                   'タスクの一時停止/再開', 'Pausar/reanudar tarea',
                                   'Jeda/lanjutkan tugas'),
    'agentTool_unknown': ('执行操作', '執行操作', 'Run action', '操作を実行', 'Ejecutar acción',
                          'Jalankan tindakan'),
    # ── 消息触发任务（收到 APRS 消息时跑一段指令）──
    'agentMessageTasks': ('消息触发', '訊息觸發', 'Message triggers', 'メッセージトリガー',
                           'Disparadores por mensaje', 'Pemicu pesan'),
    'agentMessageTasksDesc': ('收到新消息时让智能体跑一段指令', '收到新訊息時讓智慧代理跑一段指令',
                              'Run an instruction when a new message arrives',
                              '新着メッセージ受信時にエージェントが指示を実行します',
                              'Ejecuta una instrucción al recibir un mensaje nuevo',
                              'Jalankan instruksi saat pesan baru masuk'),
    'agentMessageTasksEmpty': ('暂无消息触发任务', '暫無訊息觸發任務', 'No message triggers yet',
                               'メッセージトリガーはありません', 'Aún no hay disparadores por mensaje',
                               'Belum ada pemicu pesan'),
    'agentMessageTaskNew': ('新建消息触发任务', '新建訊息觸發任務', 'New message trigger',
                            'メッセージトリガーを追加', 'Nuevo disparador por mensaje',
                            'Pemicu pesan baru'),
    'agentMessageTaskPromptHint': ('例如：把这条消息里的位置记下来', '例如：把這則訊息裡的位置記下來',
                                   'e.g. note the location in this message',
                                   '例：このメッセージ内の位置を記録する',
                                   'p. ej. anota la ubicación de este mensaje',
                                   'mis. catat lokasi pada pesan ini'),
    'agentMessageTaskEvery': ('收到消息时', '收到訊息時', 'On incoming message', 'メッセージ受信時',
                              'Al recibir un mensaje', 'Saat pesan masuk'),
    'agentMessageTaskRunPrompt': (
        '【消息触发】已启用你的第 {n} 条消息触发任务。\n任务指令：{task}\n本条新消息来自 {from}：{text}\n请执行该任务指令，只输出执行结果或结论本身，不要输出这句说明。',
        '【訊息觸發】已啟用你的第 {n} 條訊息觸發任務。\n任務指令：{task}\n這則新訊息來自 {from}：{text}\n請執行該任務指令，只輸出執行結果或結論本身，不要輸出這句說明。',
        '[Message trigger] Your message-trigger task #{n} fired.\nTask instruction: {task}\nIncoming message from {from}: {text}\nCarry out the task instruction and output only the result or conclusion, not this notice.',
        '【メッセージトリガー】{n} 番目のメッセージトリガータスクが発火しました。\nタスク指示：{task}\n受信メッセージ（{from}）：{text}\nこのタスク指示を実行し、結果または結論のみを出力してください。この説明は出力しないでください。',
        '[Disparador por mensaje] Se activó tu tarea disparadora n.º {n}.\nInstrucción: {task}\nMensaje entrante de {from}: {text}\nEjecuta la instrucción y muestra solo el resultado o la conclusión, no este aviso.',
        '[Pemicu pesan] Tugas pemicu pesan ke-{n} aktif.\nInstruksi tugas: {task}\nPesan masuk dari {from}: {text}\nJalankan instruksi tugas dan keluarkan hanya hasil atau kesimpulannya, bukan pemberitahuan ini.'),
    # ── 智能体使用告知（启用前必须签署的单独一份协议）──
    'agentNoticeTitle': ('智能体使用告知', '智慧代理使用告知', 'AI agent notice',
                         'エージェント利用に関する告知', 'Aviso sobre el agente de IA',
                         'Pemberitahuan agen AI'),
    'agentNoticeAccept': ('同意并启用', '同意並啟用', 'Agree and enable', '同意して有効化',
                          'Aceptar y activar', 'Setuju dan aktifkan'),
    'agentNoticeDecline': ('暂不启用', '暫不啟用', 'Not now', '今はしない', 'Ahora no',
                           'Nanti saja'),
    'agentNoticeBody': (
        '智能体会把你与它的对话内容，以及它读取到的本机数据（如台站、位置、消息、设置等），发送给你所配置的第三方大模型服务（如 OpenAI、DeepSeek、自建接口等）进行处理。请勿在对话中提供国家秘密、商业秘密、个人隐私或敏感位置信息。\n\n请自行确认你所选择的模型服务合法合规，并自行承担因数据出境、个人信息处理等产生的责任。我们不运营任何上述服务，与其也不存在隶属、代理或合作关系。\n\n智能体默认只能读取数据；发送消息、修改设置等有副作用的操作需要你在聊天框内单独授权并逐次确认，你也可以随时关闭智能体。\n\n点击「同意并启用」表示你已阅读、理解并接受上述内容（详见《用户协议》智能体相关条款）。',
        '智慧代理會把你與它的對話內容，以及它讀取到的本機資料（如台站、位置、訊息、設定等），傳送給你所設定的第三方大語言模型服務（如 OpenAI、DeepSeek、自建介面等）處理。請勿在對話中提供國家秘密、商業秘密、個人隱私或敏感位置資訊。\n\n請自行確認你所選擇的模型服務合法合規，並自行承擔因資料出境、個人資訊處理等產生的責任。我們不營運任何上述服務，與其也不存在隸屬、代理或合作關係。\n\n智慧代理預設只能讀取資料；傳送訊息、修改設定等有副作用的操作需要你在聊天框內單獨授權並逐次確認，你也可以隨時關閉智慧代理。\n\n點擊「同意並啟用」表示你已閱讀、理解並接受上述內容。',
        'The AI agent sends your conversation and the local data it reads (stations, location, messages, settings, …) to the third-party model service you configure (e.g. OpenAI, DeepSeek, a self-hosted endpoint) for processing. Do not share state secrets, trade secrets, personal privacy or sensitive location information in the chat.\n\nYou are responsible for confirming that the model service you choose is lawful and compliant, and you bear the consequences of any cross-border data transfer or personal-data processing. We do not operate any such service and have no affiliation, agency or partnership with it.\n\nBy default the agent can only read data; actions with side effects (sending messages, changing settings) require your separate authorization and per-action confirmation, and you can disable the agent at any time.\n\nTapping "Agree and enable" means you have read, understood and accepted the above (see the agent clauses of the User Agreement).',
        'エージェントは、あなたとの会話内容と、それが読み取った端末内データ（局・位置・メッセージ・設定など）を、あなたが設定したサードパーティのモデルサービス（OpenAI、DeepSeek、自前のエンドポイント等）に送信して処理します。会話に国家機密・企業秘密・個人のプライバシー・機微な位置情報を含めないでください。\n\n選択したモデルサービスの適法性はご自身で確認し、データの越境移転や個人情報の処理に起因する責任を負ってください。当方は当該サービスを運営しておらず、提携・代理・協力関係もありません。\n\nエージェントは既定で読み取りのみ可能です。メッセージ送信や設定変更など副作用のある操作は、チャット欄での個別の許可と都度の確認が必要で、いつでも無効化できます。\n\n「同意して有効化」を押すと、上記を読み・理解し・受け入れたものとみなされます。',
        'El agente envía tu conversación y los datos locales que lee (estaciones, ubicación, mensajes, ajustes…) al servicio de modelo de terceros que configures (p. ej. OpenAI, DeepSeek, un endpoint propio) para su procesamiento. No compartas secretos de Estado, secretos comerciales, privacidad personal ni ubicaciones sensibles en el chat.\n\nEres responsable de confirmar que el servicio de modelo que elijas sea lícito y cumpla la normativa, y asumes las consecuencias de cualquier transferencia transfronteriza de datos o tratamiento de datos personales. No operamos dicho servicio ni tenemos afiliación, agencia o sociedad con él.\n\nPor defecto el agente solo puede leer datos; las acciones con efectos (enviar mensajes, cambiar ajustes) requieren tu autorización por separado y confirmación en cada caso, y puedes desactivar el agente cuando quieras.\n\nAl pulsar «Aceptar y activar» declaras haber leído, entendido y aceptado lo anterior.',
        'Agen mengirim percakapanmu dan data lokal yang dibacanya (stasiun, lokasi, pesan, setelan, …) ke layanan model pihak ketiga yang kamu konfigurasi (mis. OpenAI, DeepSeek, endpoint sendiri) untuk diproses. Jangan bagikan rahasia negara, rahasia dagang, privasi pribadi, atau lokasi sensitif di obrolan.\n\nKamu bertanggung jawab memastikan layanan model yang kamu pilih sah dan patuh aturan, serta menanggung konsekuensi dari transfer data lintas negara atau pemrosesan data pribadi. Kami tidak mengoperasikan layanan tersebut dan tidak memiliki afiliasi, keagenan, atau kemitraan dengannya.\n\nSecara bawaan agen hanya bisa membaca data; tindakan berdampak (mengirim pesan, mengubah setelan) butuh izin terpisah darimu dan konfirmasi tiap kali, dan kamu bisa menonaktifkan agen kapan saja.\n\nDengan menekan "Setuju dan aktifkan", kamu menyatakan telah membaca, memahami, dan menerima hal di atas.'),
}
META = {
    'agentTaskEvery': '{"placeholders": {"n": {"type": "int"}}}',
    'agentAutoReplyPrompt': '{"placeholders": {"from": {"type": "String"}, "text": {"type": "String"}}}',
    'agentMessageTaskRunPrompt': '{"placeholders": {"n": {"type": "int"}, "task": {"type": "String"}, "from": {"type": "String"}, "text": {"type": "String"}}}',
}

ANCHOR = '"codeContributionTranslation"'


def _placeholders(key):
    raw = META.get(key)
    if not raw:
        return []
    return [(k, v['type']) for k, v in json.loads(raw).get('placeholders', {}).items()]


def member(key):
    ps = _placeholders(key)
    if not ps:
        return 'get %s' % key
    dart_t = {'int': 'int', 'String': 'String'}
    return '%s(%s)' % (key, ', '.join('%s %s' % (dart_t.get(t, 'String'), n) for n, t in ps))


def interp(key, text):
    for n, _ in _placeholders(key):
        text = text.replace('{%s}' % n, '$%s' % n)
    return text


def class_body(src, name):
    m = re.search(r'(?m)^(?:abstract )?class ' + re.escape(name) + r'\b', src)
    if not m:
        raise SystemExit('找不到类 ' + name)
    j = src.find('\n}\n', m.end())
    if j < 0:
        j = src.rfind('\n}')
    return m.end(), j


def main():
    for lg in LANGS:
        p = os.path.join(ROOT, 'lib', 'l10n', 'app_%s.arb' % lg)
        lines = io.open(p, encoding='utf-8').read().split('\n')
        lines = [ln for ln in lines
                 if not any(ln.strip().startswith('"%s"' % k) for k in DATA)]
        idx = next((i for i, ln in enumerate(lines)
                    if ln.strip().startswith(ANCHOR)), None)
        assert idx is not None, 'anchor not found in %s' % p
        block = []
        for k, v in DATA.items():
            block.append('  "%s": %s,' % (k, json.dumps(v[IDX[lg]], ensure_ascii=False)))
        for k, m in META.items():
            block.append('  "%s": %s,' % ('@' + k, m))
        lines[idx:idx] = block
        io.open(p, 'w', encoding='utf-8').write('\n'.join(lines))
        json.load(io.open(p, encoding='utf-8'))
        print('%s ok (+%d)' % (p, len(DATA)))

    p = os.path.join(ROOT, 'lib', 'l10n', 'app_localizations.dart')
    s = io.open(p, encoding='utf-8').read()
    code = []
    for k, v in DATA.items():
        if re.search(r'String (?:get )?%s\b' % k, s):
            continue
        code.append("  /// No description provided for @%s.\n  ///\n"
                    "  /// In zh, this message translates to:\n  /// **'%s'**\n"
                    "  String %s;\n"
                    % (k, v[0].replace('\n', ' ').replace('\r', ' '), member(k)))
    if code:
        _, j = class_body(s, 'AppLocalizations')
        s = s[:j] + '\n' + '\n'.join(code) + s[j:]
        io.open(p, 'w', encoding='utf-8').write(s)
    print('抽象类 +%d' % len(code))

    for lg in LANGS:
        fn = ('app_localizations_zh.dart' if lg in ('zh', 'zh_TW')
              else 'app_localizations_%s.dart' % lg)
        p = os.path.join(ROOT, 'lib', 'l10n', fn)
        s = io.open(p, encoding='utf-8').read()
        b0, b1 = class_body(s, CLASSES[lg])
        code = []
        for k, v in DATA.items():
            if re.search(r'String (?:get )?%s\b' % k, s[b0:b1]):
                continue
            code.append('  @override\n  String %s => %s;\n'
                        % (member(k),
                           json.dumps(interp(k, v[IDX[lg]]), ensure_ascii=False)))
        if code:
            s = s[:b1] + '\n' + '\n'.join(code) + s[b1:]
            io.open(p, 'w', encoding='utf-8').write(s)
        print('%s +%d' % (CLASSES[lg], len(code)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
