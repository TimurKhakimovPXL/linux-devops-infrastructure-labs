> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Build an OCI-Compatible Flask Web Server Image

## Goal

Build a small Flask image from a fully qualified Python base image, test it with Podman, and publish it to an OCI-compatible registry.


---

# 1. Project Structure

Place the container build files in `containers/webserver/`:

containers/  
└── webserver/  
├── app.py  
├── Containerfile  
└── requirements.txt

```
---

# 2. Python Application

## `app.py`

```python
from flask import Flask

app = Flask(__name__)

@app.route("/")
def hello():
    return "Hello from Flask inside a Podman container!"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

```
1. `Flask(__name__)` creates the application and tells Flask where to find its resources.
2. `@app.route("/")` sends requests for `/` to `hello()`.
3. The `if __name__ == "__main__"` guard starts the server only when the script is run directly.
4. `host="0.0.0.0"` listens on every container interface.

## 


## 3. Containerfile 

```
# Fully qualified
FROM docker.io/library/python:3.12-slim-bookworm


# Copy application
COPY app.py /app/app.py

WORKDIR /app

RUN pip install flask

# Container port 
EXPOSE 8080

# Run the Flask application
CMD ["python", "app.py"]

```


### 4️) Build the image using Podman

```bash

podman build -t hello-world-webserver .

```
### 5️) Run and test

```bash

podman run -d -p 8080:8080 --name hello hello-world-webserver

curl 127.0.0.1:8080

```
Output:

```

Hello, World!

```

---

### 6️) Tag and push to a registry

```bash

podman tag hello-world-webserver quay.io/YOUR_QUAY_USER/hello-world-webserver:latest

podman login quay.io

podman push quay.io/YOUR_QUAY_USER/hello-world-webserver:latest

```

Pulling the image:

```bash

podman pull quay.io/<yourusername>/hello-world-webserver:latest

podman run -d -p 8080:8080 YOUR_QUAY_USER/hello-world-webserver:latest

curl 127.0.0.1:8080

```

 **Expected output:**

```
Hello, World!
```


```
ansible-controller@lab-host:~/webserver$ podman build -t hello-world-webserver .
STEP 1/6: FROM python:3.12-slim
Resolved "python" as an alias (/etc/containers/registries.conf.d/shortnames.conf)
Trying to pull docker.io/library/python:3.12-slim...
Getting image source signatures
Copying blob d2876f169c02 done   |
Copying blob f2a111092025 done   |
Copying blob 38513bd72563 done   |
Copying blob 79f2dc6dd7d8 done   |
Copying config 324231aabb done   |
Writing manifest to image destination
STEP 2/6: WORKDIR /app
--> 3f25d1f77c85
STEP 3/6: COPY app.py .
--> 5ba0cc3c2590
STEP 4/6: RUN pip install flask
Collecting flask
  Downloading flask-3.1.2-py3-none-any.whl.metadata (3.2 kB)
Collecting blinker>=1.9.0 (from flask)
  Downloading blinker-1.9.0-py3-none-any.whl.metadata (1.6 kB)
Collecting click>=8.1.3 (from flask)
  Downloading click-8.3.0-py3-none-any.whl.metadata (2.6 kB)
Collecting itsdangerous>=2.2.0 (from flask)
  Downloading itsdangerous-2.2.0-py3-none-any.whl.metadata (1.9 kB)
Collecting jinja2>=3.1.2 (from flask)
  Downloading jinja2-3.1.6-py3-none-any.whl.metadata (2.9 kB)
Collecting markupsafe>=2.1.1 (from flask)
  Downloading markupsafe-3.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl.metadata (2.7 kB)
Collecting werkzeug>=3.1.0 (from flask)
  Downloading werkzeug-3.1.3-py3-none-any.whl.metadata (3.7 kB)
Downloading flask-3.1.2-py3-none-any.whl (103 kB)
Downloading blinker-1.9.0-py3-none-any.whl (8.5 kB)
Downloading click-8.3.0-py3-none-any.whl (107 kB)
Downloading itsdangerous-2.2.0-py3-none-any.whl (16 kB)
Downloading jinja2-3.1.6-py3-none-any.whl (134 kB)
Downloading markupsafe-3.0.3-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl (22 kB)
Downloading werkzeug-3.1.3-py3-none-any.whl (224 kB)
Installing collected packages: markupsafe, itsdangerous, click, blinker, werkzeug, jinja2, flask
Successfully installed blinker-1.9.0 click-8.3.0 flask-3.1.2 itsdangerous-2.2.0 jinja2-3.1.6 markupsafe-3.0.3 werkzeug-3.1.3
WARNING: Running pip as the 'root' user can result in broken permissions and conflicting behaviour with the system package manager, possibly rendering your system unusable. It is recommended to use a virtual environment instead: https://pip.pypa.io/warnings/venv. Use the --root-user-action option if you know what you are doing and want to suppress this warning.

[notice] A new release of pip is available: 25.0.1 -> 25.2
[notice] To update, run: pip install --upgrade pip
--> dc601cd6a50f
STEP 5/6: EXPOSE 8080
--> ef72b0bfd99d
STEP 6/6: CMD ["python", "app.py"]
COMMIT hello-world-webserver
--> b28a2d6b86ed
Successfully tagged localhost/hello-world-webserver:latest
b28a2d6b86edc3ba2536e4dd179507143266723d8946741c6db66aa0388f3031

ansible-controller@lab-host:~/webserver$ podman run -d --name hello -p 8080:8080 hello-world-webserver
3e27b8bb594f3dbe1d1f28ecceebcb94e4995090b015fa914abb61ff869a797b

ansible-controller@lab-host:~/webserver$ podman ps
CONTAINER ID  IMAGE                                   COMMAND        CREATED        STATUS        PORTS                   NAMES
3e27b8bb594f  localhost/hello-world-webserver:latest  python app.py  4 seconds ago  Up 4 seconds  0.0.0.0:8080->8080/tcp  hello

ansible-controller@lab-host:~/webserver$ curl 127.0.0.1:8080
Hello, World!

ansible-controller@lab-host:~/webserver$ podman tag hello-world-webserver:latest quay.io/YOUR_QUAY_USER/hello-world-webserver:1.0

ansible-controller@lab-host:~/webserver$ podman login quay.io
username: YOUR_QUAY_USER
Password: [entered interactively; not stored]
Login Succeeded!

ansible-controller@lab-host:~/webserver$ podman push quay.io/YOUR_QUAY_USER/hello-world-webserver:1.0

Getting image source signatures
Copying blob 8adc6fdf81f8 done   |
Copying blob 0e90c8475d80 skipped: already exists
Copying blob b17be0ee1018 skipped: already exists
Copying blob 59ff05a55d4d skipped: already exists
Copying blob 24a706aa4d69 skipped: already exists
Copying blob b7b5a65d135c skipped: already exists
Copying config b28a2d6b86 done   |
Writing manifest to image destination
```
The first push failed because the Quay repository was not available immediately after creation. Running the push again succeeded.

## Sources

- [Flask Quickstart](https://flask.palletsprojects.com/en/stable/quickstart/)
- [Docker: Containerize a Python application](https://docs.docker.com/language/python/build-images/)
- [Red Hat: Starting with containers](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/assembly_starting-with-containers_building-running-and-managing-containers)
- [Open Container Initiative](https://opencontainers.org/)
