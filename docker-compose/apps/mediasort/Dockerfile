# Media classifier (kaywoz/home0ps#260). Built on the apps VM by compose (`build:`).
FROM python:3.13-slim
RUN pip install --no-cache-dir guessit
WORKDIR /app
COPY classifier.py rules.json /app/
USER 2104:2104
EXPOSE 8089
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8089/health',timeout=3).status==200 else 1)"
CMD ["python3", "/app/classifier.py"]
