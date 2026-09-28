const filters = document.querySelectorAll("[data-filter]");
const tasks = document.querySelectorAll(".task");

filters.forEach((button) => {
  button.addEventListener("click", () => {
    filters.forEach((item) => item.classList.toggle("chosen", item === button));
    const selected = button.dataset.filter;
    tasks.forEach((task) => {
      task.hidden = selected !== "all" && task.dataset.state !== selected;
    });
  });
});
