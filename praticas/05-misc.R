## PERGUNTAS DOS ALUNOS -----------------------------------------------------

# Inverter ordem de tensor

library(torch)
library(purrr)
library(minhub)



t1 <- torch_tensor(1:10)

itens <- -c(1:10)
t1[itens]

# Deep learning em dados matriciais, raster parte do mesmo princípio
# de aplicação em imagens? SIM

# Exemplo: https://blogs.rstudio.com/ai/posts/2021-02-02-enso-prediction/

# Dicas de bom data prep

# acredito que a sugestão seja utilizar o tidymodels
# Exemplo: https://mlverse.github.io/tabnet/index.html
# https://brulee.tidymodels.org/

# R, python e Rust
## Eu acho que vale a pena saber fazer em python. Em rust não.

# Embedding na mão
nn_embedding_na_mao <- nn_module(
  initialize = function(num_embeddings, embedding_dim) {
    pesos <- torch::torch_randn(num_embeddings, embedding_dim) |>
      torch::nn_parameter()
    self$weight <- pesos
  },
  forward = function(x) {
    torch::torch_matmul(x, self$weight)
  }
)

embedding <- nn_embedding(
  num_embeddings = 9,
  embedding_dim = 3
)

embedding_na_mao <- nn_embedding_na_mao(9, 3)

embedding_linear <- nn_linear(
  9, 3, bias = FALSE
)

# colocando os mesmos pesos
embedding_na_mao$weight <- embedding$parameters$weight

# no nn_linear, tem algumas proteções contra cópia
with_no_grad(
  embedding_linear$weight$copy_(embedding$parameters$weight$t())
)

# a batch of 2 samples of 4 indices each
input <- torch_tensor(
  rbind(c(1, 2, 4, 5), c(4, 3, 2, 9)),
  dtype = torch_long()
)

input_one_hot <- nnf_one_hot(input)$to(dtype = torch_float())

embedding_na_mao(input_one_hot)
embedding(input)
embedding_linear(input_one_hot)


# SOBRE GPT -----------------------------------------------------------------

# https://blogs.rstudio.com/ai/posts/2023-06-20-llm-intro/
# https://arxiv.org/abs/1706.03762
# https://github.com/mlverse/minhub

# A GPT2 model, possibly to be used with pre-trained weights from the HuggingFace model hub.
# Documention: https://huggingface.co/docs/transformers/model_doc/gpt2

# Based on the following Python implementations:
# - https://github.com/karpathy/minGPT/blob/master/mingpt/model.py (referred to as "@Karpathy")
# - https://github.com/huggingface/transformers/blob/v4.29.1/src/transformers/models/gpt2/modeling_gpt2.py (referred to as "@Huggingface")

# See also: https://amaarora.github.io/posts/2020-02-18-annotatedGPT2.html

library(zeallot)
library(hfhub)
library(minhub)

# Following @Karpathy. See @Huggingface for an alternative implementation.
nn_gpt2_attention <- nn_module(
  initialize = function(n_embd, n_head, n_layer, max_pos, pdrop) {
    self$n_head <- n_head
    self$n_embd <- n_embd
    self$n_layer <- n_layer

    # key, query, value projections for all heads, but in a batch
    self$c_attn = nn_linear(n_embd, 3 * n_embd)
    # output projection
    self$c_proj = nn_linear(n_embd, n_embd)

    # regularization
    self$attn_dropout = nn_dropout(pdrop)
    self$resid_dropout = nn_dropout(pdrop)

    # causal mask to ensure that attention is only applied to the left in the input sequence
    self$bias <- torch_ones(max_pos, max_pos)$
      bool()$
      tril()$
      view(c(1, 1, max_pos, max_pos)) |>
      nn_buffer()

    self$reset_parameters()
  },
  forward = function(x) {
    # batch size, sequence length, embedding dimensionality (n_embd)
    c(b, t, c) %<-% x$shape

    # calculate query, key, values for all heads in batch and move head forward to be the batch dim
    c(q, k, v)  %<-% ((self$c_attn(x)$
                         split(self$n_embd, dim = -1)) |>
                        map(\(x) x$view(c(b, t, self$n_head, c / self$n_head))) |>
                        map(\(x) x$transpose(2, 3)))

    # causal self-attention; Self-attend: (B, nh, T, hs) x (B, nh, hs, T) -> (B, nh, T, T)
    att <- q$matmul(k$transpose(-2, -1)) * (1 / sqrt(k$size(-1)))
    att <- att$masked_fill(self$bias[ , , 1:t, 1:t] == 0, -Inf)
    att <- att$softmax(dim = -1)
    att <- self$attn_dropout(att)

    y <- att$matmul(v) # (B, nh, T, T) x (B, nh, T, hs) -> (B, nh, T, hs)
    y <- y$transpose(2, 3)$contiguous()$view(c(b, t, c)) # re-assemble all head outputs side by side

    # output projection
    y <- self$resid_dropout(self$c_proj(y))
    y
  },
  reset_parameters = function(initializer_range = 0.02) {
    nn_init_normal_(self$c_attn$weight, mean = 0, std = initializer_range)
    nn_init_zeros_(self$c_attn$bias)
    nn_init_normal_(self$c_proj$weight, mean = 0, std = initializer_range/sqrt(2 * self$n_layer))
    nn_init_zeros_(self$c_proj$bias)
  }
)

nn_gpt2_mlp <- nn_module(
  initialize = function(n_embd, pdrop) {
    self$c_fc <- nn_linear(n_embd, 4 * n_embd)
    self$c_proj <- nn_linear(4 * n_embd, n_embd)
    self$act <- nn_gelu(approximate = "tanh")
    self$dropout <- nn_dropout(pdrop)

    self$reset_parameters()
  },
  forward = function(x) {
    x |>
      self$c_fc() |>
      self$act() |>
      self$c_proj() |>
      self$dropout()
  },
  reset_parameters = function(initializer_range = 0.02) {
    nn_init_normal_(self$c_fc$weight, mean = 0, std = initializer_range)
    nn_init_zeros_(self$c_fc$bias)
    nn_init_normal_(self$c_proj$weight, mean = 0, std = initializer_range)
    nn_init_zeros_(self$c_proj$bias)
  }
)

nn_gpt2_transformer_block <- nn_module(
  initialize = function(n_embd, n_head, n_layer, max_pos, pdrop) {
    self$ln_1 <- nn_layer_norm(n_embd, eps = 1e-5)
    self$attn <- nn_gpt2_attention(n_embd, n_head, n_layer, max_pos, pdrop)
    self$ln_2 <- nn_layer_norm(n_embd, eps = 1e-5)
    self$mlp <- nn_gpt2_mlp(n_embd, pdrop)
  },
  forward = function(x) {
    x <- x + self$attn(self$ln_1(x))
    x + self$mlp(self$ln_2(x))
  }
)

nn_gpt2_model <- nn_module(
  initialize = function(vocab_size, n_embd, n_head, n_layer, max_pos, pdrop) {
    self$n_layer <- n_layer

    self$transformer <- nn_module_dict(list(
      wte = nn_embedding(vocab_size, n_embd),
      wpe = nn_embedding(max_pos, n_embd),
      drop = nn_dropout(pdrop),
      h = nn_sequential(!!!map(
        1:n_layer,
        \(x) nn_gpt2_transformer_block(n_embd, n_head, n_layer, max_pos, pdrop)
      )),
      ln_f = nn_layer_norm(n_embd, eps = 1e-5)
    ))

    self$lm_head <- nn_linear(n_embd, vocab_size, bias = FALSE)

    self$reset_parameters()
  },
  forward = function(x) {
    tok_emb <- self$transformer$wte(x) # token embeddings of shape (b, t, n_embd)

    pos <- torch_arange(1, x$size(2), device=x$device)$to(dtype="long")$unsqueeze(1) # shape (1, t)
    pos_emb <- self$transformer$wpe(pos) # position embeddings of shape (1, t, n_embd)

    x <- self$transformer$drop(tok_emb + pos_emb)
    x <- self$transformer$h(x)
    x <- self$transformer$ln_f(x)
    x <- self$lm_head(x)
    x
  },
  reset_parameters = function(initializer_range = 0.02) {
    # These initializations are in both @Karpathy and @Huggingface (e.g., https://github.com/huggingface/transformers/blob/118e9810687dd713b6be07af79e80eeb1d916908/src/transformers/models/gpt2/modeling_gpt2.py#L455)
    nn_init_normal_(self$transformer$wte$weight, mean = 0, std = initializer_range)
    nn_init_normal_(self$transformer$wte$weight, mean = 0, std = initializer_range)
    nn_init_zeros_(self$transformer$ln_f$bias)
    nn_init_ones_(self$transformer$ln_f$weight)
    nn_init_normal_(self$lm_head$weight, mean = 0, std = initializer_range)
    # The following is both in @Karpathy and in @Huggingface (quote from: https://github.com/huggingface/transformers/blob/118e9810687dd713b6be07af79e80eeb1d916908/src/transformers/models/gpt2/modeling_gpt2.py#LL471C9-L476C111)
    # Reinitialize selected weights subject to the OpenAI GPT-2 Paper Scheme:
    #   > A modified initialization which accounts for the accumulation on the residual path with model depth. Scale
    #   > the weights of residual layers at initialization by a factor of 1/√N where N is the # of residual layers.
    #   >   -- GPT-2 :: https://openai.com/blog/better-language-models/
    #
    # Reference (Megatron-LM): https://github.com/NVIDIA/Megatron-LM/blob/main/megatron/model/gpt_model.py
    parameters <- self$named_parameters()
    imap(parameters, function(par, nm) {
      if (grepl("c_proj.weight", nm, fixed = TRUE)) {
        nn_init_normal_(par, mean = 0, std = initializer_range/sqrt(2 * self$n_layer))
      }
    })
  }
)

#' GPT2
#'
#' Initializes a gpt2-type model
#'
#' @param vocab_size An optional integer indicating the size of the vocabulary or the number of unique tokens in the input data.
#' @param n_embd An integer specifying the Dimensionality of the embeddings and hidden states.
#' @param n_head An integer representing the number of attention heads in each attention layer in the Transformer encoder.
#' @param n_layer An integer indicating the umber of hidden layers in the Transformer encoder.
#' @param max_pos An integer specifying the maximum sequence length that this model might ever be used with.
#' @param pdrop The dropout rate used in a few locations, such as after the embeddings,
#'   attention layers and residual connections.
#' @returns An initialized [torch::nn_module()].
#' @export
gpt2 <- function(vocab_size = 50257, n_embd = 768, n_head = 12, n_layer = 12,
                 max_pos = 1024, pdrop = 0.1) {
  nn_gpt2_model(vocab_size, n_embd, n_head, n_layer, max_pos, pdrop)
}

#' @describeIn gpt2 Initializes a gpt2 model using a configuration defined in HF Hub
#' @param identifier A string representing the identifier or name of the pre-trained model in the Hugging Face model hub.
#' @param revision A string specifying the revision or version of the pre-trained model in the Hugging Face model hub.
#' @export
gpt2_from_config <- function(identifier, revision = "main") {
  path <- hfhub::hub_download(identifier, "config.json", revision = revision)
  config <- jsonlite::fromJSON(path)

  if (config$model_type != "gpt2")
    cli::cli_abort(c(
      "{.arg config$model_type} must be {.val gpt2}, got {.val {config$model_type}}"
    ))

  if (config$layer_norm_eps != 1e-5)
    cli::cli_abort("{.arg config$layer_norm_eps} must be {.val 1e-5}.")

  pdrop <- unlist(config[c("resid_pdrop", "embd_pdrop", "attn_pdrop")])
  if (length(unique(pdrop)) != 1)
    cli::cli_abort("{.arg {names(pdrop)}} must be all equal, but got {pdrop}")
  else
    pdrop <- unique(pdrop)

  if (config$initializer_range != 0.02)
    cli::cli_abort("{.arg initializer_range} must be {.val 0.02}, got {config$initializer_range}")

  vocab_size <- config$vocab_size
  n_embd     <- config$n_embd
  n_head     <- config$n_head
  n_layer    <- config$n_layer
  max_pos    <- config$n_positions

  gpt2(vocab_size, n_embd, n_head, n_layer, max_pos, pdrop)
}

#' @describeIn gpt2 Initializes the gpt2 model and load pre-trained weights from HF hub.
#' @param identifier A string representing the identifier or name of the pre-trained model in the Hugging Face model hub.
#' @param revision A string specifying the revision or version of the pre-trained model in the Hugging Face model hub.
#' @export
gpt2_from_pretrained <- function(identifier, revision = "main") {
  with_device(device = "meta", {
    model <- gpt2_from_config(identifier, revision)
  })
  state_dict <- hf_state_dict(identifier, revision)
  state_dict <- gpt2_hf_weights_remap(state_dict)
  state_dict$lm_head.weight <- state_dict$transformer.wte.weight
  state_dict <- gpt2_hf_weights_transpose(state_dict)
  model$load_state_dict(state_dict, .refer_to_state_dict = TRUE)
  model
}

gpt2_hf_weights_remap <- function(state_dict) {
  old_names <- names(state_dict)
  new_names <- paste0("transformer.", old_names)
  names(state_dict) <- new_names
  state_dict
}

gpt2_hf_weights_transpose <- function(state_dict) {
  to_be_transposed <- c("attn.c_attn.weight", "attn.c_proj.weight", "mlp.c_fc.weight", "mlp.c_proj.weight")
  for (nm in names(state_dict)) {
    if (any(endsWith(nm, to_be_transposed))) {
      state_dict[[nm]]$t_() # transpose in-place
    }
  }
  state_dict
}


## APLICAÇÃO -------------------------------------------------------------------
identifier <- "gpt2"
revision <- "e7da7f2"
# instantiate model and load Hugging Face weights
model <- gpt2_from_pretrained(identifier, revision)
# load matching tokenizer
tok <- tok::tokenizer$from_pretrained(identifier)
model$eval()

idx <- torch_tensor(
  tok$encode(
    paste0(
      "Be not afraid of greatness. Some are born great, some achieve greatness, and others"
    )
  )$ids
)$view(c(1, -1))

idx

prompt_length <- idx$size(-1)

for (i in 1:30) { # decide on maximal length of output sequence
  # obtain next prediction (raw score)
  with_no_grad({
    logits <- model(idx + 1L)
  })
  last_logits <- logits[, -1, ]
  # pick highest scores (how many is up to you)
  c(prob, ind) %<-% last_logits$topk(50)
  last_logits <- torch_full_like(last_logits, -Inf)$scatter_(-1, ind, prob)
  # convert to probabilities
  probs <- nnf_softmax(last_logits, dim = -1)
  # probabilistic sampling
  id_next <- torch_multinomial(probs, num_samples = 1) - 1L
  # stop if end of sequence predicted
  if (id_next$item() == 0) {
    break
  }
  # append prediction to prompt
  idx <- torch_cat(list(idx, id_next), dim = 2)
}

tok$decode(as.integer(idx))

resultado_correto <- " have greatness thrust upon them."

