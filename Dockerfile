FROM public.ecr.aws/lambda/python:3.11

COPY lambda_function.py ${LAMBDA_TASK_ROOT}

CMD ["lambda_function.lambda_handler"]
