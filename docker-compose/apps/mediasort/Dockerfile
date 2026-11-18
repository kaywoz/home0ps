# Media classifier (kaywoz/home0ps#260). Built by .github/workflows/build-mediasort.yml and pushed to
# ghcr.io/kaywoz/mediasort:latest; the apps VM still builds it locally (`build:`) until it retires.
FROM python:3.13-slim
RUN pip install --no-cache-dir guessit anthropic openai
WORKDIR /app
COPY --chmod=644 classifier.py rules.json /app/
USER 2104:2104
EXPOSE 8089
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8089/health',timeout=3).status==200 else 1)"
CMD ["python3", "/app/classifier.py"]
