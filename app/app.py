from flask import Flask, render_template
import os

app = Flask(__name__)

@app.route("/")
def index():
    version = os.getenv("APP_VERSION", "1.0.0")
    return render_template("index.html", version=version)

@app.route("/health")
def health():
    return {"status": "ok"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)