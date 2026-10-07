#! /usr/bin/env python3
# web_server.py
import os, sys, time
import threading, logging, uuid, base64, json
from functools import wraps
from cua_engine import CUA_Engine
from flask import Flask, render_template, request, jsonify, send_from_directory, Response, stream_with_context #Flask laod 1s
from flask_socketio import SocketIO,emit  #SocketIO load 2s
import requests  #load 2s
from requests.auth import HTTPBasicAuth

app = Flask(__name__)
app.config['SECRET_KEY'] = 'secret!'
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# 全局引擎实例
cua_engine = None
engine_lock = threading.Lock()
task_thread = None
is_task_running = False

# 鉴权相关全局变量
# 用于存储第一个用户的鉴权 token
# None 表示还没有用户访问，一个唯一的 token 表示第一个用户已存在
first_user_token = None
ENABLE_AUTH = '--auth' in sys.argv


import logging


# 默认配置
DEFAULT_SETTINGS = {
    'api_type': 'DashScope',
    'api_key': 'sk-xxxxxxxx',
    'base_url': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'model_name': 'qwen3-vl-plus-2025-09-23',
    'img_keep_n': 3,
    'max_rounds': 20,
    'initial_prompt': """You are an intelligent assistant operating on an IP-KVM. You have the ability to see the computer's desktop via screenshots and execute keyboard and mouse actions.
Core Objective: Observe the screen via screenshots and use the provided commands to achieve the user's goal step-by-step.
Your response will be parsed into keyboard and mouse action commands. Please strictly adhere to the specified format. When the task is complete, output "Done" to terminate the session.
Note: Each response must contain only 1 or 2 lines of action commands. For multi-step operations, you must respond in multiple turns. After each turn, you will wait for the operation to complete and receive a new screenshot as feedback. You will then decide the next step based on the latest screenshot.

1. Mouse Operation: mouse x y c
    x,y: The normalized coordinates relative to the screen width and height(accurate to three decimal places) to move the mouse to. If 0,0, the mouse position does not change.
    c: The mouse button action. 0 = no action, 1 = left-click, 2 = right-click, 3 = left double-click, 4 = right double-click, 5 = scroll down once, 6 = scroll up once.
2. Drag Operation: drag x0 y0 x1 y1
    x0,y0: The starting normalized position(accurate to three decimal places) where the left mouse button is pressed.
    x1,y1: The ending normalized position(accurate to three decimal places) where the left mouse button is released after dragging.
3. Keyboard Operation: keyboard key_desc
    key_desc is a string representing the keypress, e.g., a, A, F11, CTRL+C, CTRL+SHIFT+A, ALT+F4, GUI+L.
    Special key strings are defined as: ENTER, ESCAPE, BACKSPACE, TAB, SPACE, CAPS_LOCK, RIGHT_ARROW, LEFT_ARROW, DOWN_ARROW, UP_ARROW, LEFT_CONTROL, LEFT_SHIFT, LEFT_ALT, LEFT_GUI, RIGHT_CONTROL, RIGHT_SHIFT, RIGHT_ALT, RIGHT_GUI.
4. Typing Operation: typestr content
    content: The string to be typed. It must only consist of visible ASCII characters. Do not attempt to type non-printable characters (e.g., newline, tab). Use the 'keyboard' command with keys like ENTER or TAB for such actions.
5. Deletion Operation: backspace n
    n: The number of characters to delete using the backspace key.
6. Sleep Operation: sleep second
    second: The duration of the delay in seconds. It can be a decimal, e.g., 0.5.

Important Guidelines:
1. Before moving the cursor, you MUST inspect the screenshot to determine the precise coordinates of the target element. If a click fails, you must analyze the new screenshot, note the last cursor's position, and adjust the coordinates for your next attempt.
2. Before typing, you MUST check the screenshot to ensure the target input field has focus and clear any existing text if necessary. After typing, verify that the text has been entered completely and correctly, without omissions or duplications.
3. After performing actions that require a wait time (e.g., opening a webpage, application, or file; saving or dragging a file), you MUST wait for the next screenshot to confirm that the previous action has successfully completed before proceeding. This is critical.
4. Always be aware of the currently focused window. If pop-ups or other windows are obstructing your target, you may need to close them first.
5. You MUST precede your action commands with two lines of comments, each starting with #. The first line should briefly describe the key content on the current screen. The second line should describe what your subsequent command(s) aim to achieve.
6. If you require additional information from the user (such as a username, password, product name, etc.), output a line starting with $ to request it, like this: $Please have the user input the [required information] to continue. Your turn will pause until the user provides the information.
7. If recent attempts consistently yield unexpected results, try using a different approach instead of repeating the same action.
"""
}

def load_config():
    """Load settings from cua_cfg.json or use defaults."""
    global DEFAULT_SETTINGS
    config_file_path = '/kvmapp/cua/cua_cfg.json'
    if os.path.exists(config_file_path):
        try:
            with open(config_file_path, 'r', encoding='utf-8') as f:
                config = json.load(f)
                DEFAULT_SETTINGS.update(config)
                print("Settings loaded successfully from cua_cfg.json.")
        except Exception as e:
            print(f"Error loading config file: {e}. Using default settings.")
    else:
        print("Config file 'cua_cfg.json' not found. Using default settings.")

def save_config(settings):
    """Saves the current settings to cua_cfg.json."""
    config_file_path = '/kvmapp/cua/cua_cfg.json'
    try:
        with open(config_file_path, 'w', encoding='utf-8') as f:
            json.dump(settings, f, indent=4, ensure_ascii=False)
        print("Settings saved to cua_cfg.json.")
    except Exception as e:
        print(f"Error saving config file: {e}")

def dummy_init_engine():
    # dummy init, load openai lib (takes 5~10s)
    global cua_engine
    with engine_lock:
        if cua_engine is None:
            print("Dummy initializing CUA_Engine...")
            cua_engine = CUA_Engine(
                api_type=DEFAULT_SETTINGS['api_type'],
                api_key=DEFAULT_SETTINGS['api_key'],
                base_url=DEFAULT_SETTINGS['base_url'],
                model_name=DEFAULT_SETTINGS['model_name'],
                img_keep_n=DEFAULT_SETTINGS['img_keep_n'],
                max_rounds=DEFAULT_SETTINGS['max_rounds'],
                initial_prompt=DEFAULT_SETTINGS['initial_prompt']
            )
            print("CUA_Engine initialized.")


# 鉴权装饰器
def auth_required(f):
    @wraps(f)  # 这是关键的修改，确保保留原始函数元数据
    def decorated_function(*args, **kwargs):
        global first_user_token, ENABLE_AUTH
        # 如果鉴权未启用，则直接放行
        if not ENABLE_AUTH:
            return f(*args, **kwargs)

        user_token = request.headers.get('X-Auth-Token')
        if not user_token or user_token != first_user_token:
            return jsonify({'status': 'error', 'message': 'Unauthorized access.'}), 403
        return f(*args, **kwargs)
    return decorated_function

# 用于鉴权 desktop_snapshot_proxy 的装饰器
def desktop_auth_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        global first_user_token, ENABLE_AUTH
        if not ENABLE_AUTH:
            return f(*args, **kwargs)

        # 从 URL 查询参数中获取 token
        user_token = request.args.get('token')
        if not user_token or user_token != first_user_token:
            print(f"Auth failed for desktop stream. User token: {user_token}")
            return "Unauthorized access.", 403
        return f(*args, **kwargs)
    return decorated_function


# 获取 Flask 的 logger
log = logging.getLogger('werkzeug')
log.setLevel(logging.WARNING)  # 全局设置，会影响所有路由

@app.route('/')
def index():
    global first_user_token, ENABLE_AUTH
    if ENABLE_AUTH:
        if first_user_token is None:
            # 第一次访问，为该用户生成一个唯一的 token
            first_user_token = str(uuid.uuid4())
            print(f"Generated a new auth token for the first user: {first_user_token}")
            return render_template('index.html', auth_token=first_user_token, is_auth_enabled=True)
        else:
            # 不是第一个用户，返回拒绝访问的页面或消息
            return "This session is only for single user.", 403

    # 鉴权未启用，正常返回页面
    return render_template('index.html', auth_token=None, is_auth_enabled=False)

@app.route('/settings', methods=['GET', 'POST'])
@auth_required
def handle_settings():
    global cua_engine, DEFAULT_SETTINGS
    if request.method == 'POST':
        data = request.json
        if "api_type" in data and data["api_type"] != DEFAULT_SETTINGS['api_type']:
            # 如果更改了 api_type，重置引擎
            with engine_lock:
                cua_engine = None
        # 更新默认设置
        DEFAULT_SETTINGS.update({
            'api_type': data.get('api_type', DEFAULT_SETTINGS['api_type']),
            'api_key': data.get('api_key', DEFAULT_SETTINGS['api_key']),
            'base_url': data.get('base_url', DEFAULT_SETTINGS['base_url']),
            'model_name': data.get('model_name', DEFAULT_SETTINGS['model_name']),
            'img_keep_n': int(data.get('img_keep_n', DEFAULT_SETTINGS['img_keep_n'])),
            'max_rounds': int(data.get('max_rounds', DEFAULT_SETTINGS['max_rounds'])),
            'initial_prompt': data.get('initial_prompt', DEFAULT_SETTINGS['initial_prompt'])
        })
        save_config(DEFAULT_SETTINGS)
        if cua_engine == None:
            dummy_init_engine()
        return jsonify({'status': 'success', 'message': 'Settings saved.'})
    else:
        return jsonify(DEFAULT_SETTINGS)

@app.route('/start_task', methods=['POST'])
@auth_required
def start_task():
    global cua_engine, task_thread, is_task_running, DEFAULT_SETTINGS
    if is_task_running:
        return jsonify({'status': 'error', 'message': 'Task is already running.'})

    data = request.json
    task_desc = data.get('task_desc', '').strip()
    if not task_desc:
        return jsonify({'status': 'error', 'message': 'Task description is required.'})

    # 使用设置初始化引擎
    full_prompt = DEFAULT_SETTINGS['initial_prompt'] + "\n\n现在我下达的操作目标为：" + task_desc
    with engine_lock:
        cua_engine = CUA_Engine(
            api_type=DEFAULT_SETTINGS['api_type'],
            api_key=DEFAULT_SETTINGS['api_key'],
            base_url=DEFAULT_SETTINGS['base_url'],
            model_name=DEFAULT_SETTINGS['model_name'],
            img_keep_n=DEFAULT_SETTINGS['img_keep_n'],
            max_rounds=DEFAULT_SETTINGS['max_rounds'],
            initial_prompt=full_prompt
        )


    is_task_running = True

    # 启动后台线程执行任务
    def run_task():
        global is_task_running
        while is_task_running and cua_engine:
            with engine_lock:
                if not cua_engine:
                    break
                result = cua_engine.step()
            # 通过WebSocket将结果推送给前端
            socketio.emit('task_update', result)

            if result['status'] in ['done', 'error']:
                is_task_running = False
                break

            # 如果任务被暂停或等待用户输入，则在此处等待
            if result['status'] in ['paused', 'waiting_for_user']:
                # 我们不在这里阻塞，而是通过前端的resume指令来唤醒
                # 这里可以加一个小延时，避免过于频繁的循环
                time.sleep(1)
                continue

            # 正常执行，加一个小延时
            time.sleep(0.1)

    task_thread = threading.Thread(target=run_task)
    task_thread.start()
    return jsonify({'status': 'success', 'message': 'Task started.'})

@app.route('/pause_task', methods=['POST'])
@auth_required
def pause_task():
    global cua_engine, is_task_running
    if not is_task_running or not cua_engine:
        return jsonify({'status': 'error', 'message': 'No task is running.'})

    with engine_lock:
        if cua_engine:
            cua_engine.pause()
    return jsonify({'status': 'success', 'message': 'Task paused.'})

@app.route('/resume_task', methods=['POST'])
@auth_required
def resume_task():
    global cua_engine, is_task_running
    if not is_task_running or not cua_engine:
        return jsonify({'status': 'error', 'message': 'No task is running.'})

    data = request.json
    user_input = data.get('user_input', '')

    with engine_lock:
        if cua_engine:
            cua_engine.resume_with_input(user_input)

    return jsonify({'status': 'success', 'message': 'Task resumed.'})

@app.route('/reset_task', methods=['POST'])
@auth_required
def reset_task():
    global cua_engine, is_task_running, task_thread
    with engine_lock:
        if cua_engine:
            cua_engine.reset()
        cua_engine = None
    is_task_running = False
    if task_thread and task_thread.is_alive():
        # 注意：我们无法强制终止线程，只能等待它自然结束
        # 在实际应用中，您可能需要更复杂的线程管理
        pass
    return jsonify({'status': 'success', 'message': 'Task reset.'})

@app.route('/get_status', methods=['GET'])
@auth_required
def get_status():
    global cua_engine, is_task_running
    if not cua_engine:
        return jsonify({'status': 'idle'})
    with engine_lock:
        engine_status = cua_engine.get_status()
    return jsonify({
        'status': 'running' if is_task_running else 'idle',
        'engine': engine_status
    })

@app.route('/desktop-snapshot')
@desktop_auth_required
def desktop_snapshot_proxy():
    """
    代理路由：获取桌面视频流（MJPEG）。
    前端应请求此路由，而不是直接请求外部URL。
    """
    print(f"Received request for /desktop-snapshot from {request.remote_addr}")
    try:
        target_url = "https://localhost/api/stream/mjpeg"

        resp = requests.get(target_url, timeout=10, verify=False, stream=True)
        print(f"Successfully connected to target. Status code: {resp.status_code}")
        print(f"Target Content-Type: {resp.headers.get('Content-Type')}")

        def generate():
            print("Starting to stream content to client.")
            try:
                for chunk in resp.iter_content(chunk_size=1024):
                    if chunk:
                        yield chunk
            except Exception as e:
                print(f"Streaming error: {e}")
            finally:
                resp.close()
                print("Finished streaming content.")

        # 👇 关键：使用 stream_with_context 包装生成器，确保上下文不丢失
        return Response(
            stream_with_context(generate()),
            status=resp.status_code,
            mimetype=resp.headers.get('Content-Type', 'multipart/x-mixed-replace'),
            headers={
                'Cache-Control': 'no-cache, no-store, must-revalidate',
                'Pragma': 'no-cache',
                'Expires': '0',
                'Connection': 'close'
            }
        )

    except requests.exceptions.Timeout:
        print("Connection to target URL timed out.")
        return "Proxy Error: Connection timed out.", 504
    except requests.exceptions.RequestException as e:
        print(f"Request failed with an exception: {str(e)}", exc_info=True)
        return f"Proxy Error: {str(e)}", 503

# WebSocket 连接鉴权
@socketio.on('connect')
def handle_connect():
    global first_user_token, ENABLE_AUTH
    dummy_init_engine()
    if ENABLE_AUTH:
        # 获取 WebSocket 请求头中的 token
        user_token = request.headers.get('X-Auth-Token')
        if not user_token or user_token != first_user_token:
            print("WebSocket connection denied due to invalid token.")
            return False  # 拒绝连接

    print("WebSocket connection established.")

@socketio.on('disconnect')
def handle_disconnect():
    global first_user_token, ENABLE_AUTH
    if ENABLE_AUTH:
        print("WebSocket disconnected. Shutting down the server.")
        os._exit(0)


if __name__ == '__main__':
    load_config()
    if ENABLE_AUTH:
        print("Authentication is ENABLED. Only the first visitor will be granted access.")
        print("Run with `python cua_webapp.py` to disable authentication.")
    else:
        print("Authentication is DISABLED. All visitors can access the application.")

    socketio.run(app, host='0.0.0.0', port=5000, debug=False, allow_unsafe_werkzeug=True)

